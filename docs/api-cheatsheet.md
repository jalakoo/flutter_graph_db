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
| `db.close()` | `Future<void>` | Flush + release. |

See the [umbrella README](../packages/flutter_graph_db/README.md) for
the per-platform persistence wiring and the conditional import.

## Catalog / interning

| Call | Returns | Notes |
|---|---|---|
| `db.internLabel(name)` | `int` | Idempotent — returns the existing id if already interned. |
| `db.internEdgeType(name)` | `int` | |
| `db.internPropKey(name)` | `int` | |
| `db.labelName(id)` | `String?` | Reverse lookup. `null` if unknown. |
| `db.edgeTypeName(id)` / `db.propKeyName(id)` | `String?` | |

## Write — `db.runTransaction((txn) { ... })`

A transaction commits atomically on normal return and rolls back on any
throw. `runTransaction` forwards the body's return value, so you can
hand back the `Vid`/`Eid` you just allocated. Single-writer: a nested
or concurrent `runTransaction` throws `StateError`.

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
| `db.labelScan(labelId)` | `Uint32List` | **Raw int** vids carrying the label, ascending. Read-your-writes. Wrap each in `Vid(..)` for the typed accessors; do not mutate the list. |
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
| `db.state.mergeNow()` | Fold the overlay into the CSR (empties pending writes). Required before `encodeSnapshot`. |
| `encodeSnapshot(db.state)` → `.bytes` | Serialize current state. |
| `compactToCurrentTip(store: store)` | Truncate the WAL after persisting a snapshot. |

The snapshot + compact cycle is documented end-to-end in the
[umbrella README](../packages/flutter_graph_db/README.md#snapshot--compact-cycle-long-running-apps).

> **WAL growth — there is no automatic checkpoint yet.** The WAL appends
> on every commit and only shrinks when *you* run the snapshot + compact
> cycle above. In a long-running app, trigger it on a write-count or
> file-size threshold (or at backgrounding) — otherwise the WAL grows
> unbounded and startup recovery slows in proportion.

## Errors

| Family | Meaning | Retry? |
|---|---|---|
| `TransientException` | Temporary; safe to retry as-is. | Yes |
| `DataException` (e.g. `ConstraintViolation`, `NotFoundException`) | Caller-side bug or invalid input. | No — fix the input. |
| `FatalException` (e.g. `CorruptionDetected`) | Corruption / version mismatch. | No — close the DB, surface it. |
| `StateError` | Lifecycle violation (nested txn, closed handle). | No — fix the call site. |

All graph errors descend from the sealed `GraphDbException`.
