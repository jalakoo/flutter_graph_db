# graph_db_sync

Push-only sync engine. Drains a local WAL past each remote target's
high-water mark, translates `WalOp`s into `ImportOp`s, and ships them
via `RemoteGraphClient.bulkImport`. Multi-target dispatch + per-target
quarantine queue + `fullExport` seeding mode for fresh targets.

## Usage

```dart
import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:graph_db_remote_neo4j/graph_db_remote_neo4j.dart';
import 'package:graph_db_sync/graph_db_sync.dart';

final engine = SyncEngine(
  db: db,
  walStore: store,
  targets: [
    SyncTarget(
      name: 'prod-neo4j',
      client: Neo4jBoltClient(host: '...', port: 7687, auth: ...),
      seedingMode: SeedingMode.fullExport, // first-time seed
    ),
    SyncTarget(
      name: 'analytics-falkor',
      client: FalkorClient(host: '...', port: 6379, graphName: 'g'),
      seedingMode: SeedingMode.incremental,
    ),
  ],
);

// Run on demand, on a timer, or in response to a change stream —
// `syncOnce` is explicit; the engine doesn't auto-schedule.
final reports = await engine.syncOnce();
for (final r in reports) {
  print(r); // SyncRunReport(name: shipped=N, quarantined=M, hwm=A→B, …)
}
```

## Semantics

- **Per-target HWM** — each `SyncTarget` tracks the LSN it's last
  shipped past. `syncOnce` walks the WAL from `target.hwm + 1`
  forward. Pass a `SyncStateStore` to make it durable (see below);
  without one the HWM is in-memory and a restart re-ships the whole
  retained WAL.
- **Quarantine on rejection** — if a target's `bulkImport` throws a
  `RemoteException`, the batch lands in `target.quarantine` (with the
  reason + timestamp) and the HWM stays put. Later runs retry from
  the same HWM; survivors land, failures re-quarantine.
- **Multi-target independence** — one target's failure doesn't block
  another's progress. Each gets its own `SyncRunReport`.
- **Seeding modes** —
  - `incremental` (default): straight WAL drain from `hwm`.
  - `fullExport`: merges the overlay, enumerates the CSR + overlay-added
    nodes + CSR edges into one bulk import, advances HWM to
    `db.currentLsn`. Used for new targets that need to be seeded from
    the current state of the graph.

## Unlabeled remote nodes

`graph_db_core` requires every node to carry at least one label (see
the multi-label plan §4.6). When syncing from a remote backend that
allows label-less nodes (e.g. Neo4j permits `CREATE (n {p: 1})`), the
sync engine substitutes `'unlabeled_node'` and emits a `stderr`
warning on each substitution:

```text
[graph_db_sync] WARNING: remote node "<logicalId>" had no labels;
  substituting fallback label "unlabeled_node". Override via
  SyncEngine.unlabeledFallback or filter these nodes upstream.
```

Override the fallback label via
`engine.unlabeledFallback = 'External';`, or set it to `null` to
reject unlabelled remote nodes with a `SyncException` instead — useful
for projects whose schema invariant is "every node must have a label"
and you want data-quality issues to surface at the boundary instead
of being papered over.

## Durable progress

Give the engine a `SyncStateStore` and call `restore()` once at startup.
Each target's HWM is then persisted as soon as the remote acknowledges a
batch, so a restart resumes instead of re-shipping the retained WAL:

```dart
import 'package:graph_db_sync/io_sync_state_store.dart'; // native only

final stateStore = await IoSyncStateStore.open('${dir.path}/sync.json');
final engine = SyncEngine(
  db: db,
  walStore: store,
  targets: [...],
  stateStore: stateStore,
);
await engine.restore();   // reload HWMs before the first syncOnce
```

`InMemorySyncStateStore` is the platform-neutral adapter for tests. A
target with no persisted entry keeps its defaults, so adding a target to
an existing deployment seeds it normally.

Writes are atomic (temp file + rename), so a crash leaves the previous
complete state rather than a half-written file that would lose every
target's progress at once.

## Carry-forwards

- HLC + LWW conflict resolution — depends on the adapter surfacing
  richer conflict-detection metadata than the current single
  `RemoteConstraintViolation`.
- Opt-in remote-constraint pull — depends on
  `RemoteGraphClient.listConstraints()` being implemented by the
  adapter you're syncing to.
