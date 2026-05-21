import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

/// Read-your-writes for the GQL surface — `6_IMPROVED_API_PLAN.md` Gate 4.
///
/// The executor's `NodeScan` / `Expand` are already overlay-aware, so a
/// `MATCH` over a freshly-committed-but-unmerged node/edge returns it
/// without `mergeNow()`. These lock that behavior against regression.

GraphDb _emptyDb() {
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const [],
    edgeTypeNames: const [],
    vidSpace: 16,
    eidSpace: 16,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('read-your-writes — GQL', () {
    test('MATCH returns a node committed via runTransaction before any merge',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final nameKey = db.internPropKey('name');
      await db.runTransaction((txn) {
        txn.addNode(
          labelIds: [label],
          props: {nameKey: const PropString('Kai')},
        );
      });
      // No mergeNow().
      final r = await db.executeQuery('MATCH (n:Thing) RETURN n.name AS name');
      expect(r.rows.map((row) => row.values['name']), contains('Kai'));
    });

    test('MATCH expand returns an edge committed before any merge', () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final rel = db.internEdgeType('rel');
      final nameKey = db.internPropKey('name');
      await db.runTransaction((txn) {
        final a = txn.addNode(
            labelIds: [label], props: {nameKey: const PropString('A')});
        final b = txn.addNode(
            labelIds: [label], props: {nameKey: const PropString('B')});
        txn.addEdge(src: a, dst: b, typeId: rel);
      });
      final r = await db.executeQuery(
        'MATCH (a:Thing)-[:rel]->(b:Thing) RETURN a.name AS src, b.name AS dst',
      );
      expect(r.rows.single.values['src'], 'A');
      expect(r.rows.single.values['dst'], 'B');
    });
  });
}
