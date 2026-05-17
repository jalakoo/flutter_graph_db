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
  forward.
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

## Carry-forwards

- HWM persistence (snapshotted alongside the engine's snapshot meta)
  — today the HWM is in-memory per `SyncTarget`. Persistence is a
  drop-in.
- HLC + LWW conflict resolution — depends on the adapter surfacing
  richer conflict-detection metadata than the current single
  `RemoteConstraintViolation`.
- Opt-in remote-constraint pull — depends on
  `RemoteGraphClient.listConstraints()` being implemented by the
  adapter you're syncing to.
