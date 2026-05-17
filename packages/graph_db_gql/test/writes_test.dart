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
  group('CREATE', () {
    test('CREATE (n:Label {props}) lands a new node', () async {
      final db = await _empty();
      await db.executeQuery(
        "CREATE (n:Person {name: 'Ada', age: 36})",
      );
      // Verify via a follow-up MATCH
      final r = await db.executeQuery('MATCH (n:Person) RETURN n.name, n.age');
      expect(r.length, 1);
      expect(r.rows.single.values['n.name'], 'Ada');
      expect(r.rows.single.values['n.age'], 36);
    });

    test('CREATE chain (a:L)-[:T]->(b:L)', () async {
      final db = await _empty();
      await db.executeQuery(
        "CREATE (a:Person {name: 'X'})-[:knows]->(b:Person {name: 'Y'})",
      );
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows]->(b:Person) '
        'RETURN a.name AS src, b.name AS dst',
      );
      expect(r.rows.single.values['src'], 'X');
      expect(r.rows.single.values['dst'], 'Y');
    });

    test('CREATE without :Label rejected', () async {
      final db = await _empty();
      await expectLater(
        () => db.executeQuery('CREATE (n)'),
        throwsA(isA<PlannerException>()),
      );
    });
  });

  group('SET', () {
    test('SET n.prop = literal', () async {
      final db = await _empty();
      await db.executeQuery(
        "CREATE (n:Person {name: 'Ada', age: 36})",
      );
      await db.executeQuery(
        "MATCH (n:Person) WHERE n.name = 'Ada' SET n.age = 37",
      );
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.age',
      );
      expect(r.rows.single.values['n.age'], 37);
    });

    test('SET multiple properties', () async {
      final db = await _empty();
      await db.executeQuery(
        "CREATE (n:Person {name: 'Ada'})",
      );
      await db.executeQuery(
        "MATCH (n:Person) SET n.age = 30, n.city = 'NYC'",
      );
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.age, n.city',
      );
      expect(r.rows.single.values['n.age'], 30);
      expect(r.rows.single.values['n.city'], 'NYC');
    });

    test('SET with RETURN projects the post-mutation value', () async {
      final db = await _empty();
      await db.executeQuery(
        "CREATE (n:Person {name: 'Ada', age: 36})",
      );
      final r = await db.executeQuery(
        'MATCH (n:Person) SET n.age = 99 RETURN n.age',
      );
      expect(r.rows.single.values['n.age'], 99);
    });
  });

  group('DELETE', () {
    test('DELETE removes the node from subsequent matches', () async {
      final db = await _empty();
      await db.executeQuery("CREATE (n:Person {name: 'Ada'})");
      await db.executeQuery("CREATE (n:Person {name: 'Bob'})");
      await db.executeQuery(
        "MATCH (n:Person) WHERE n.name = 'Ada' DELETE n",
      );
      final r = await db.executeQuery('MATCH (n:Person) RETURN n.name');
      expect(r.length, 1);
      expect(r.rows.single.values['n.name'], 'Bob');
    });
  });
}
