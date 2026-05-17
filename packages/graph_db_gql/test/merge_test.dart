import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

Future<GraphDb> _empty() async {
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
  group('MERGE single-node (plan §8 / Phase 3E polish)', () {
    test('creates the node when no match', () async {
      final db = await _empty();
      await db.executeQuery(
        "MERGE (n:Person {name: 'Ada'})",
      );
      final r = await db.executeQuery('MATCH (n:Person) RETURN n.name');
      expect(r.length, 1);
      expect(r.rows.single.values['n.name'], 'Ada');
    });

    test('reuses the existing node on second MERGE', () async {
      final db = await _empty();
      await db.executeQuery("MERGE (n:Person {name: 'Ada'})");
      await db.executeQuery("MERGE (n:Person {name: 'Ada'})");
      final r =
          await db.executeQuery('MATCH (n:Person) RETURN COUNT(*)');
      expect(r.rows.single.values.values.single, 1);
    });

    test('different props create a separate node', () async {
      final db = await _empty();
      await db.executeQuery("MERGE (n:Person {name: 'Ada'})");
      await db.executeQuery("MERGE (n:Person {name: 'Bob'})");
      final r =
          await db.executeQuery('MATCH (n:Person) RETURN COUNT(*)');
      expect(r.rows.single.values.values.single, 2);
    });

    test('MERGE with relationships rejected (v1)', () async {
      final db = await _empty();
      await expectLater(
        () => db.executeQuery(
          'MERGE (a:Person)-[:knows]->(b:Person)',
        ),
        throwsA(isA<GqlParseException>()),
      );
    });
  });
}
