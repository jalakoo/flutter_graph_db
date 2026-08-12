import 'package:flutter_graph_db/flutter_graph_db.dart';
import 'package:test/test.dart';

/// The umbrella package had no tests at all, so nothing verified that its
/// three re-exported barrels compose — a name collision between
/// `graph_db_core`, `graph_db_wal`, and `graph_db_gql` would only have
/// surfaced in a consumer's build.
///
/// These deliberately use *only* the umbrella import: if a symbol below
/// stops resolving, the umbrella has stopped re-exporting something its
/// documented quick-start depends on.

void main() {
  test('the one-import quick-start from the README compiles and runs',
      () async {
    final db = await openWalBackedGraphDb(store: InMemoryWalStore());
    final s = db.defineSchema(
      labels: {'Person'},
      edgeTypes: {'KNOWS'},
      propKeys: {'name': ColumnType.string, 'score': ColumnType.double_},
    );

    final ada = await s.add('Person', {'name': 'Ada', 'score': 9});
    final bob = await s.add('Person', {'name': 'Bob'});
    await db.runTransaction(
        (txn) => txn.addEdge(src: ada, dst: bob, typeId: s.edgeType('KNOWS')));

    expect(s.find('name', 'Ada'), ada);
    expect(s.outNeighbors(ada, 'KNOWS'), [bob]);
    // `int` 9 promotes to the declared double column.
    expect(db.getNodeDoubleProp(ada, s.propKey('score')), 9.0);

    await db.close();
  });

  test('the int-keyed hot path is reachable through the umbrella', () async {
    final db = await openWalBackedGraphDb(store: InMemoryWalStore());
    final person = db.internLabel('Person');
    final knows = db.internEdgeType('KNOWS');
    final name = db.internPropKey('name');

    final ada = await db.runTransaction((txn) {
      final a = txn.addNode(
          labelIds: [person], props: {name: const PropString('Ada')});
      final b = txn.addNode(
          labelIds: [person], props: {name: const PropString('Bob')});
      txn.addEdge(src: a, dst: b, typeId: knows);
      return a;
    });

    expect(db.labelScan(person), hasLength(2));
    expect(db.getNodeStringProp(Vid(ada.value), name), 'Ada');
    expect(db.outDegree(ada), 1);

    await db.runTransaction((txn) => txn.delNode(ada));
    expect(db.isNodeVisible(ada), isFalse);
    await db.close();
  });

  test('the GQL surface is re-exported', () async {
    final db = await openWalBackedGraphDb(store: InMemoryWalStore());
    final s = db.defineSchema(
      labels: {'Person'},
      propKeys: {'name': ColumnType.string},
    );
    await s.add('Person', {'name': 'Ada'});

    final result =
        await db.executeQuery('MATCH (n:Person) RETURN n.name AS name');

    expect(result.rows, hasLength(1));
    expect(result.rows.single.values['name'], 'Ada');
    await db.close();
  });

  test('core, wal, and gql symbols all resolve from the one import', () {
    // Types only — a compile-time check that the barrels don't shadow or
    // drop each other's exports.
    expect(GraphDb, isNotNull); // graph_db_core
    expect(InMemoryWalStore, isNotNull); // graph_db_wal
    expect(WalCodec, isNotNull); // graph_db_wal
    expect(InMemorySnapshotStore, isNotNull); // graph_db_wal
    expect(CheckpointPolicy, isNotNull); // graph_db_wal
    expect(PropString, isNotNull); // graph_db_core
    expect(IndexSpec, isNotNull); // graph_db_core
    expect(ConstraintViolation, isNotNull); // graph_db_core
    expect(Vid, isNotNull); // graph_db_core
  });

  test('the durable-open path composes across packages', () async {
    final store = InMemoryWalStore();
    final snaps = InMemorySnapshotStore();
    var db = await openWalBackedGraphDb(
      store: store,
      snapshotStore: snaps,
      checkpoint: CheckpointPolicy.manual,
    );
    final s = db.defineSchema(
      labels: {'Person'},
      propKeys: {'name': ColumnType.string},
    );
    final ada = await s.add('Person', {'name': 'Ada'});

    // Snapshot, then reopen from it — exercises the core codec through
    // the wal package's recovery entry point.
    db.mergeNow();
    await snaps.write(db.captureSnapshot().bytes);
    db = await openWalBackedGraphDb(store: store, snapshotStore: snaps);

    expect(db.isNodeVisible(ada), isTrue);
    expect(db.findNodeByProp(db.propKeyId('name')!, const PropString('Ada')),
        ada);
  });
}
