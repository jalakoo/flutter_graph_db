# graph_db_core

Engine package — CSR topology, columnar property store, transactional
applicator, public read / write API. The substantive engine code lives
here; everything else in the family wraps it.

This is one of nine packages — most Flutter apps depend on the
[`flutter_graph_db`](../flutter_graph_db) umbrella instead and get
`graph_db_core` transitively. Depend on this package directly only
if you want minimum dependency surface (no WAL, no GQL, no remote
adapters).

## What's in here

- `GraphDb` — the public façade. `runTransaction`, `outDegree` /
  `outNeighbors` / range-style reads, label scans, property accessors.
  (`src/graph_db.dart`)
- **CSR topology** — `Uint32List` row pointer / column index / edge id
  arrays for both directions. Cross-platform (web-safe).
- **Columnar property store** — per-key typed columns
  (`Float64List` / `Uint8List` / `Uint32List` / `List<String>`),
  raw on the hot path, boxed to `PropValue` only at the API boundary.
- **Per-vid delta overlay + worker-isolate merge** — mutations land
  in the overlay; on a threshold, a background isolate copy-folds it
  into a fresh CSR and the main isolate installs via pointer swap.
  Web targets fall back to a synchronous main-isolate fold.
- **Secondary indexes** — sorted-array equality + range indexes with
  optional hash overlay + incremental inserts. Declare
  `IndexSpec(valueType: …)` to build an index on an empty graph, before
  the column exists.
- **Logical-id index** — every node's `logicalId` is durably indexed:
  `db.nodeByLogicalId(id)` (O(1), unique) and `db.getNodeLogicalId(vid)`.
- **Constraint catalog** — `UniqueConstraint` / `ExistenceConstraint`
  enforced inside `runTransaction`.
- **Snapshot codec** — `encodeSnapshot` / `decodeSnapshot` for a
  whole-state JSON blob. Pairs with `graph_db_wal`'s
  `compactToCurrentTip` for the snapshot + WAL-truncate cycle.

## Minimum-viable example

```dart
import 'dart:typed_data';
import 'package:graph_db_core/graph_db_core.dart';

Future<void> main() async {
  final db = GraphDb.fromState(MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const [],
    edgeTypeNames: const [],
    vidSpace: 1024,
    eidSpace: 1024,
  ));

  final person = db.internLabel('Person');
  final knows = db.internEdgeType('KNOWS');
  final name = db.internPropKey('name');

  await db.runTransaction((txn) {
    final ada = txn.addNode(labelIds: [person], props: {
      name: const PropString('Ada'),
    });
    final bob = txn.addNode(labelIds: [person], props: {
      name: const PropString('Bob'),
    });
    txn.addEdge(src: ada, dst: bob, typeId: knows);
  });

  print('${db.nodeCount} nodes, ${db.edgeCount} edges');
  for (final v in db.labelScan(person)) {
    final n = db.getNodeStringProp(v, name);
    print('  ${v.value}: $n (out-degree ${db.outDegree(v)})');
  }
}
```

For WAL-backed persistence, see
[`graph_db_wal`](../graph_db_wal). For an OpenCypher query layer, see
[`graph_db_gql`](../graph_db_gql). For both at once via a single
import, see the [`flutter_graph_db`](../flutter_graph_db) umbrella.

