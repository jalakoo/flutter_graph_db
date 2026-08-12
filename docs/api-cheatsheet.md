# API cheatsheet

The consumer-facing surface of `flutter_graph_db`, grouped by task. One
import covers all of it:

```dart
import 'package:flutter_graph_db/flutter_graph_db.dart';
```

This is the curated *what-do-I-call* view. For the exhaustive,
always-in-sync reference (every parameter, every overload), generate
the dartdoc — see [API reference](../README.md#api-reference).

> **Ids are typed and 32-bit.** `Vid` (node) and `Eid` (edge) are
> zero-cost `extension type`s over `int`. They are monotonic and never
> reused — a deleted id leaves a permanent gap. Catalog names (labels,
> edge types, property keys) are interned to plain `int` ids.

---

## Open / close

| Call | Returns | Notes |
|---|---|---|
| `openWalBackedGraphDb(store: InMemoryWalStore())` | `Future<GraphDb>` | In-memory — no persistence (tests / scratch). |
| `openWalBackedGraphDb(store: await IoWalStore.open(path))` | `Future<GraphDb>` | Native (iOS / Android / desktop). Import `package:graph_db_wal/io_wal_store.dart`. Recovers the prior session automatically. |
| `openWalBackedGraphDb(store: await openIndexedDbWalStore())` | `Future<GraphDb>` | Web. Import `package:graph_db_wal/indexeddb_wal_store.dart`. |
| `openWalBackedGraphDb(store: store, snapshot: bytes)` | `Future<GraphDb>` | Restore a snapshot, then replay WAL appended after it. |
| `openGraphDbAtPath(path)` | `Future<DurableGraphDb>` | **One-call durable open** (native; import `io_wal_store.dart`). Wires WAL + snapshot store, restores the latest snapshot, replays the tail, and auto-checkpoints. Use `handle.db`, `handle.checkpointNow()`, `handle.close()`. |
| `db.close()` | `Future<void>` | Flush + release. Idempotent — 2nd+ call is a no-op. |

See the [umbrella README](../packages/flutter_graph_db/README.md) for
the per-platform persistence wiring and the conditional import.

## Schema & ergonomic tier — start here

The API is tiered. **Most app code wants the ergonomic tier:** declare a
schema once, then work in names and raw Dart values. The int-keyed catalog
and `PropValue` methods below it are the allocation-conscious **hot path**
(bulk import, inner loops) — reach for them when you measure a need.

Declare the schema once. It's a non-transactional but **journaled**
idempotent schema op: column type-locks are recorded in the WAL and
carried in the snapshot, so they survive a restart and re-declaring on
each open is optional (harmless when the types match, throws when one
conflicts with persisted data):

```dart
final s = db.defineSchema(
  labels: {'Phrase', 'Context'},
  edgeTypes: {'IN_CONTEXT', 'RELATES_TO'},
  propKeys: {'name': ColumnType.string, 'score': ColumnType.double_},
);
```

| Call | Returns | Notes |
|---|---|---|
| `db.defineSchema({labels, edgeTypes, propKeys})` | `GraphSchema` | Interns the names; reserves a typed column per declared prop key. `propKeys` maps name → `ColumnType`. |
| `s.label(name)` / `s.edgeType(name)` / `s.propKey(name)` | `int` | Cached handle. Throws `ArgumentError` if `name` wasn't declared. |
| `await s.add(label, {props}, {logicalId})` | `Vid` | Raw values boxed per column type: `int`→`double` promotes; lossy / mismatched types throw. Undeclared keys → strict-by-Dart-type. `null` → `PropNull`. |
| `s.find(propKey, value, {label})` | `Vid?` | First match. Query value boxed like the write, so `find('score', 3)` matches a stored `3.0`. `label:` scopes the scan. |
| `s.findAll(propKey, value, {label})` | `List<Vid>` | All matches, ascending. |
| `s.outNeighbors(vid, edgeType)` / `s.inNeighbors(vid, edgeType)` | `List<Vid>` | Neighbours reached by one edge type. Read-your-writes. |

```dart
final v = await s.add('Phrase', {'name': 'こんにちは', 'score': 3}); // score → 3.0
final hit = s.find('name', 'こんにちは');
final related = s.outNeighbors(v, 'RELATES_TO');
```

> **Zero-setup on-ramp:** for scratch/tests, the string-keyed
> `txn.addNodeNamed` / `setNodePropNamed` (under *Write*) auto-intern names
> without a schema. Graduate to `defineSchema` for typed columns + cached
> handles.

## Catalog / interning

*Hot path / catalog primitives. The schema tier above wraps these — use them
directly for bulk paths or when you hold int handles already.*

| Call | Returns | Notes |
|---|---|---|
| `db.internLabel(name)` | `int` | Idempotent — returns the existing id if already interned. |
| `db.internEdgeType(name)` | `int` | |
| `db.internPropKey(name)` | `int` | |
| `db.labelName(id)` | `String?` | Reverse lookup (id → name). `null` if unknown. |
| `db.edgeTypeName(id)` / `db.propKeyName(id)` | `String?` | |
| `db.labelId(name)` | `int?` | Name → id, **without** interning. `null` if not yet interned — use to read by name without creating a catalog entry. |
| `db.edgeTypeId(name)` / `db.propKeyId(name)` | `int?` | |

## Write — `db.runTransaction((txn) { ... })`

A transaction commits atomically on normal return and rolls back on any
throw. `runTransaction` forwards the body's return value, so you can
hand back the `Vid`/`Eid` you just allocated. Single-writer: a nested
or concurrent `runTransaction` throws `StateError`.

**No reads inside the body.** The txn is buffer-only, so a high-level
read (`db.nodeCount`, `db.getNodeProp`, `db.labelScan`, …) issued while
it's in flight throws `StateError` rather than silently returning
pre-commit state. Read before the transaction, or after it commits
(committed writes are read-your-writes).

| Call (on `txn`) | Returns | Notes |
|---|---|---|
| `txn.addNode(labelIds: [..], props: {keyId: PropValue})` | `Vid` | `props` optional; `logicalId` defaults to a fresh UUIDv7. |
| `txn.addEdge(src: vid, dst: vid, typeId: id, props: {..})` | `Eid` | `props` optional. |
| `txn.setNodeProp(vid, keyId, PropValue)` | `void` | Insert or overwrite. |
| `txn.setEdgeProp(eid, keyId, PropValue)` | `void` | |
| `txn.delNodeProp(vid, keyId)` / `txn.delEdgeProp(eid, keyId)` | `void` | |
| `txn.setNodeLabels(vid, added: [..], removed: [..])` | `void` | Multi-label add/remove in one op. |
| `txn.delNode(vid)` | `void` | Tombstones the node **and cascades its incident edges**. |
| `txn.delEdge(eid)` | `void` | |
| `txn.declareConstraint(spec)` / `txn.dropConstraint(name)` | `void` | Unique / existence constraints. |

**String-keyed convenience** (auto-intern names; the int-keyed methods
above stay the hot path):

| Call (on `txn`) | Returns | Notes |
|---|---|---|
| `txn.addNodeNamed(labels: ['Person'], props: {'name': PropString('Ada')})` | `Vid` | Interns labels + prop keys. |
| `txn.addEdgeNamed(src: a, dst: b, type: 'KNOWS', props: {..})` | `Eid` | Interns edge type + prop keys. |
| `txn.setNodePropNamed(vid, 'name', value)` / `txn.setEdgePropNamed(eid, 'k', value)` | `void` | Interns the key. |

```dart
final db2 = await db.runTransaction(
  (txn) { /* ... */ return value; },
  durability: Durability.fsync,   // optional per-call override
  capturePrevValues: true,        // optional: record old values for audit/sync
);
```

## Read — counts & topology

All read-your-writes: a committed mutation is reflected immediately, no
`mergeNow()`.

| Call | Returns | Notes |
|---|---|---|
| `db.nodeCount` / `db.edgeCount` | `int` | Deleted ids keep their slot, so counts can exceed live logical entities. |
| `db.outDegree(vid)` / `db.inDegree(vid)` | `int` | |
| `db.hasLabel(vid, labelId)` | `bool` | |
| `db.labelsOf(vid)` | `Iterable<int>` | View — do not mutate. |
| `db.hasPendingWrites` | `bool` | True while committed writes await the next merge. Only relevant to the primitive range API below. |

## Read — scan & traverse

| Call | Returns | Notes |
|---|---|---|
| `db.labelScan(labelId)` | `Uint32List` | **Raw int** vids carrying the label, ascending. Read-your-writes. Allocation-free hot path; do not mutate the list. |
| `db.labelScanVids(labelId)` | `Iterable<Vid>` | Typed, lazy view over `labelScan` — no copy, no `Vid(..)` wrapping at the call site. Read-your-writes. |
| `db.forEachOutNeighbor(vid, (dst, eid, edgeType) { .. })` | `void` | Read-your-writes. Skips removed edges and deleted endpoints. |
| `db.forEachInNeighbor(vid, (src, eid, edgeType) { .. })` | `void` | Read-your-writes. |
| `db.outRangeStart(vid)` / `outRangeEnd(vid)` / `outNeighborAt(i)` / `edgeIdAt(i)` / `edgeTypeAt(i)` | `int` / `Vid` / `Eid` | **Allocation-free, snapshot-of-last-merge — NOT read-your-writes.** Hot path only. `in*` equivalents exist. Guard with `hasPendingWrites`. |

```dart
for (final id in db.labelScan(person)) {
  final v = Vid(id);
  db.forEachOutNeighbor(v, (dst, eid, type) {
    // visit each out-edge of v
  });
}
```

## Read — properties

Use the typed accessor matching the column type; they return raw
primitives with no boxing. Guard with `hasNodeProp` / `nodePropIsNull`
when the presence/type isn't certain.

| Call | Returns | Notes |
|---|---|---|
| `db.getNodeStringProp(vid, keyId)` | `String` | Also `getNodeIntProp`, `getNodeDoubleProp`, `getNodeBoolProp`. |
| `db.getEdgeStringProp(eid, keyId)` / `db.getEdgeIntProp(eid, keyId)` | `String` / `int` | |
| `db.hasNodeProp(vid, keyId)` | `bool` | Also `hasEdgeProp`. |
| `db.nodePropIsNull(vid, keyId)` | `bool` | |
| `db.nodePropType(keyId)` | `ColumnType?` | Also `edgePropType`. |
| `db.getNodeProp(vid, keyId)` | `PropValue?` | Boxed boundary form (allocates) — `getEdgeProp` too. Prefer typed accessors on the hot path. |

### Find nodes by property

Read-your-writes scans over the labelled set — saves the
`labelScan` + per-vid compare boilerplate. Allocation-free per row (the
comparison reads the raw typed column), but still O(n) in the label; for
large equality-heavy workloads build a `createNodePropertyIndex` instead
— on an empty graph (no column yet) pass
`IndexSpec(valueType: ColumnType.…)` to declare the index ahead of any
writes.

Index declarations are journaled: they come back on the next open with
their contents rebuilt from the recovered columns, so an index does not
have to be re-created after a restart.

| Call | Returns | Notes |
|---|---|---|
| `db.findNodeByProp(keyId, value, {label})` | `Vid?` | First match, or `null`. `value` is a `PropValue`; pass `label:` to scan one label, omit to scan all. Absent/NULL never matches a non-null value. For a unique id, prefer `nodeByLogicalId`. |
| `db.findNodesByProp(keyId, value, {label})` | `List<Vid>` | All matches, ascending by vid. |

### Logical id (built-in unique index)

Every node carries a `logicalId` (the UUIDv7 `addNode` mints, or the
value you pass). The engine indexes it — no need to invent your own
`extId` property + secondary index.

| Call | Returns | Notes |
|---|---|---|
| `db.nodeByLogicalId(logicalId)` | `Vid?` | O(1) lookup. Read-your-writes. logicalId is **unique** — adding a duplicate throws `ConstraintViolation`. |
| `db.getNodeLogicalId(vid)` | `String?` | The node's logicalId, or `null` if none / deleted. |
| `txn.addNode(..., logicalId: 'my-id')` | `Vid` | Supply your own stable id instead of the default UUIDv7. |

### `PropValue` types

| Class | Dart type | Storable? |
|---|---|---|
| `PropInt` / `PropDouble` / `PropBool` / `PropString` | `int` / `double` / `bool` / `String` | Yes |
| `PropNull` | explicit null | Yes |
| `PropList` / `PropMap` | `List` / `Map` of `PropValue` | **No** — boundary only; storing one throws `ConstraintViolation`. |

```dart
props: {name: const PropString('Ada'), age: const PropInt(36)}
```

## Query — GQL (OpenCypher subset)

Provided by `graph_db_gql` (re-exported by the umbrella) as an
extension method. If you never call it, the language code tree-shakes
out.

| Call | Returns | Notes |
|---|---|---|
| `db.executeQuery(query, [params])` | `Future<QueryResult>` | `params` is an optional `Map<String, Object?>`. |
| `result.columns` | `List<String>` | RETURN aliases, in order. |
| `result.rows` | `List<ResultRow>` | Also `result.length` / `isEmpty` / `isNotEmpty`. |
| `row.values[alias]` | `Object?` | Per-row value map. |

```dart
final result = await db.executeQuery(
  'MATCH (n:Person) WHERE n.age > \$min RETURN n.name AS name',
  {'min': 30},
);
for (final row in result.rows) {
  print(row.values['name']);
}
```

## Durability & persistence lifecycle

| Symbol | Notes |
|---|---|
| `Durability.group` | **Default** — commit lands in the next 1ms group-fsync window. |
| `Durability.fsync` | Per-commit fsync. Strongest, slowest. |
| `Durability.periodic` / `Durability.none` | Timer-synced / RAM-only (tests). |
| `db.mergeNow()` | Fold the overlay into the CSR (empties pending writes). Required before `encodeSnapshot`. |
| `encodeSnapshot(db.state)` → `.bytes` | Serialize current state. |
| `compactToCurrentTip(store: store)` | Truncate the WAL after persisting a snapshot. |

### Automatic checkpointing (no manual cycle needed)

| Symbol | Notes |
|---|---|
| `SnapshotStore` | Port for persisting/loading the latest snapshot. Adapters: `InMemorySnapshotStore`, `IoSnapshotStore` (native), `IndexedDbSnapshotStore` (web, via `openIndexedDbSnapshotStore()`). |
| `CheckpointPolicy.auto(maxWalBytes:, everyCommits:)` | Auto-checkpoint thresholds (default 8 MiB). `CheckpointPolicy.manual` / `.disabled` to opt out. |
| `CheckpointCoordinator(db:, walStore:, snapshotStore:, policy:)..attach()` | Wires the post-commit hook. Writes the snapshot durably, *then* truncates the WAL (crash-safe). |
| `coordinator.checkpointNow()` | Force a checkpoint (e.g. on backgrounding). |

`openGraphDbAtPath` wires all of this for you — most apps never touch
the coordinator directly. For a custom store, `openWalBackedGraphDb` also
accepts `snapshotStore:` + `checkpoint:`:

```dart
openWalBackedGraphDb(
  store: store,
  snapshotStore: snaps,
  checkpoint: CheckpointPolicy.auto(maxWalBytes: 1 << 20),
);
```

The manual snapshot + compact cycle is still documented in the
[umbrella README](../packages/flutter_graph_db/README.md#snapshot--compact-cycle-long-running-apps).

## Errors

| Family | Meaning | Retry? |
|---|---|---|
| `TransientException` | Temporary; safe to retry as-is. | Yes |
| `DataException` (e.g. `ConstraintViolation`, `NotFoundException`) | Caller-side bug or invalid input. | No — fix the input. |
| `FatalException` (e.g. `CorruptionDetected`) | Corruption / version mismatch. | No — close the DB, surface it. |
| `StateError` | Lifecycle violation (nested txn, closed handle). | No — fix the call site. |

All graph errors descend from the sealed `GraphDbException`.
