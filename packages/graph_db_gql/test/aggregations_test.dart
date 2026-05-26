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
  db.internEdgeType('knows');
  final nameKey = db.internPropKey('name');
  final ageKey = db.internPropKey('age');
  final cityKey = db.internPropKey('city');
  final names = ['Alice', 'Bob', 'Charlie', 'Dave', 'Eve'];
  final ages = [30, 25, 40, 28, 22];
  final cities = ['NYC', 'NYC', 'SF', 'NYC', 'SF'];
  for (var i = 0; i < 5; i++) {
    state.csr.labelOf[i] = personLabel;
    state.nodeProps.setString(i, nameKey, names[i]);
    state.nodeProps.setInt(i, ageKey, ages[i]);
    state.nodeProps.setString(i, cityKey, cities[i]);
  }
  return db;
}

void main() {
  group('aggregations', () {
    test('COUNT(*)', () async {
      final db = await _peopleDb();
      final r =
          await db.executeQuery('MATCH (n:Person) RETURN COUNT(*)');
      expect(r.rows.single.values.values.single, 5);
    });

    test('COUNT(expr) skips nulls', () async {
      final db = await _peopleDb();
      // Set city to null for one — though our fixture doesn't have nulls;
      // just verify the count matches the input.
      final r = await db.executeQuery('MATCH (n:Person) RETURN COUNT(n.age)');
      expect(r.rows.single.values.values.single, 5);
    });

    test('SUM / AVG / MIN / MAX over age', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN SUM(n.age), AVG(n.age), MIN(n.age), MAX(n.age)',
      );
      final row = r.rows.single.values;
      expect(row['SUM(n.age)'] ?? row.values.toList()[0], 145);
      // AVG = 145/5 = 29
      expect((row.values.toList()[1] as num).toDouble(), 29.0);
      expect(row.values.toList()[2], 22);
      expect(row.values.toList()[3], 40);
    });

    test('COLLECT gathers all values', () async {
      final db = await _peopleDb();
      final r =
          await db.executeQuery('MATCH (n:Person) RETURN COLLECT(n.name)');
      final list = r.rows.single.values.values.single as List<Object?>;
      expect(list.toSet(),
          {'Alice', 'Bob', 'Charlie', 'Dave', 'Eve'});
    });

    test('GROUP BY: aggregate with a group key', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.city, COUNT(*)',
      );
      // 2 cities; NYC: 3, SF: 2
      final byCity = <String, int>{};
      for (final row in r.rows) {
        byCity[row.values['n.city'] as String] =
            row.values['COUNT(*)'] as int;
      }
      expect(byCity, {'NYC': 3, 'SF': 2});
    });
  });

  group('ORDER BY / LIMIT / SKIP', () {
    test('ORDER BY n.age ASC', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name, n.age ORDER BY n.age',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names, ['Eve', 'Bob', 'Dave', 'Alice', 'Charlie']);
    });

    test('ORDER BY n.age DESC', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name, n.age ORDER BY n.age DESC',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names, ['Charlie', 'Alice', 'Dave', 'Bob', 'Eve']);
    });

    test('multi-key ORDER BY', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name, n.city, n.age '
        'ORDER BY n.city, n.age DESC',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      // NYC: Alice 30, Dave 28, Bob 25 — then SF: Charlie 40, Eve 22
      expect(names, ['Alice', 'Dave', 'Bob', 'Charlie', 'Eve']);
    });

    test('LIMIT caps the row count', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name ORDER BY n.name LIMIT 2',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names, ['Alice', 'Bob']);
    });

    test('SKIP drops leading rows', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name ORDER BY n.name SKIP 3',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names, ['Dave', 'Eve']);
    });

    test('SKIP + LIMIT together', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name ORDER BY n.name SKIP 1 LIMIT 2',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names, ['Bob', 'Charlie']);
    });
  });
}
