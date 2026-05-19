import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

Future<GraphDb> _peopleDb() async {
  final state = MutableGraphState.fromFixture(
    nodeCount: 5,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(5),
    labelNames: const ['Person'],
    edgeTypeNames: const ['knows'],
    vidSpace: 16,
    eidSpace: 16,
  );
  final db = GraphDb.fromState(state);
  final personLabel = db.internLabel('Person');
  final nameKey = db.internPropKey('name');
  final ageKey = db.internPropKey('age');
  final names = ['Alice', 'Bob', 'Charlie', 'Dave', 'Eve'];
  final ages = [30, 25, 40, 28, 22];
  for (var i = 0; i < 5; i++) {
    db.state.csr.labelOf[i] = personLabel;
    db.state.nodeProps.setString(i, nameKey, names[i]);
    db.state.nodeProps.setInt(i, ageKey, ages[i]);
  }
  return db;
}

void main() {
  group('parameters (plan §8 / Phase 3F)', () {
    test('numeric \$param in WHERE', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        r'MATCH (n:Person) WHERE n.age > $minAge RETURN n.name',
        {'minAge': 28},
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Charlie']);
    });

    test('string \$param in equality', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        r'MATCH (n:Person) WHERE n.name = $who RETURN n.age',
        {'who': 'Bob'},
      );
      expect(r.rows.single.values['n.age'], 25);
    });

    test('missing param raises EvalException', () async {
      final db = await _peopleDb();
      await expectLater(
        () => db.executeQuery(
          r'MATCH (n:Person) WHERE n.name = $who RETURN n',
        ),
        throwsA(isA<EvalException>()),
      );
    });
  });

  group('plan cache (plan §8 / Phase 3F)', () {
    test('caches by query string; same plan reused', () async {
      final db = await _peopleDb();
      final cache = db.gqlPlanCache;
      expect(cache.length, 0);
      await db.executeQuery('MATCH (n:Person) RETURN n.name');
      expect(cache.length, 1);
      await db.executeQuery('MATCH (n:Person) RETURN n.name');
      expect(cache.length, 1);
      await db.executeQuery('MATCH (n:Person) RETURN n.age');
      expect(cache.length, 2);
    });

    test('LRU evicts least-recently-used past maxEntries', () {
      final cache = GqlPlanCache(maxEntries: 2);
      final p1 = NodeScan(alias: 'a', labelIds: null) as LogicalPlan;
      final p2 = NodeScan(alias: 'b', labelIds: null) as LogicalPlan;
      final p3 = NodeScan(alias: 'c', labelIds: null) as LogicalPlan;
      cache.put('q1', p1);
      cache.put('q2', p2);
      expect(cache.length, 2);
      // Touch q1 → q2 becomes LRU
      cache.get('q1');
      cache.put('q3', p3);
      expect(cache.get('q1'), isNotNull);
      expect(cache.get('q2'), isNull);
      expect(cache.get('q3'), isNotNull);
    });

    test('invalidateAll empties the cache', () async {
      final db = await _peopleDb();
      await db.executeQuery('MATCH (n:Person) RETURN n.name');
      expect(db.gqlPlanCache.length, 1);
      db.gqlPlanCache.invalidateAll();
      expect(db.gqlPlanCache.length, 0);
    });
  });

  group('Cypher-compat scalar functions (plan §8 / Phase 3F)', () {
    test('size(string) returns its length', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        "MATCH (n:Person) WHERE size(n.name) = 3 RETURN n.name",
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Bob', 'Eve']);
    });

    test('length(string) is an alias for size(string)', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        "MATCH (n:Person) WHERE length(n.name) > 4 RETURN n.name",
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Charlie']);
    });

    test('coalesce returns the first non-null arg', () async {
      final db = await _peopleDb();
      // No "nickname" key set → coalesce falls through to n.name.
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN coalesce(n.nickname, n.name) AS who',
      );
      final names = r.rows.map((x) => x.values['who']).toList();
      expect(names..sort(),
          ['Alice', 'Bob', 'Charlie', 'Dave', 'Eve']);
    });
  });
}
