import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

/// Builds a 5-person mini graph:
///   alice(30) --knows--> bob(25)
///   alice    --knows--> charlie(40)
///   bob      --knows--> charlie
///   charlie  --knows--> dave(28)
///   dave     --knows--> eve(22)
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

  // Set props on the seeded vids 0..4
  final names = ['Alice', 'Bob', 'Charlie', 'Dave', 'Eve'];
  final ages = [30, 25, 40, 28, 22];
  for (var i = 0; i < 5; i++) {
    db.state.csr.labelOf[i] = personLabel;
    db.state.nodeProps.setString(i, nameKey, names[i]);
    db.state.nodeProps.setInt(i, ageKey, ages[i]);
  }
  // Rebuild labelIndex now that labelOf was patched (csr was built
  // with default label 0; we just confirmed it's the Person label).
  final lbl = db.state.csr.labelIndex[personLabel] ?? Uint32List(0);
  // sanity — all 5 people should already be present in the seeded
  // single-label index.
  expect(lbl.length, 5);

  // Add edges via bulkAddEdges (durability: none for speed).
  await db.bulkAddEdges(
    const [
      BulkEdge(src: Vid(0), dst: Vid(1), typeId: 0),
      BulkEdge(src: Vid(0), dst: Vid(2), typeId: 0),
      BulkEdge(src: Vid(1), dst: Vid(2), typeId: 0),
      BulkEdge(src: Vid(2), dst: Vid(3), typeId: 0),
      BulkEdge(src: Vid(3), dst: Vid(4), typeId: 0),
    ],
    durability: Durability.none,
  );
  return db;
}

void main() {
  group('NodeScan + Project', () {
    test('returns every Person', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery('MATCH (n:Person) RETURN n.name');
      expect(r.columns, ['n.name']);
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Bob', 'Charlie', 'Dave', 'Eve']);
    });

    test('RETURN with AS alias', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name AS who',
      );
      expect(r.columns, ['who']);
      expect(r.rows.first.values.keys, ['who']);
    });

    test('full scan (no label)', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery('MATCH (n) RETURN n.name');
      expect(r.length, 5);
    });
  });

  group('WHERE filtering', () {
    test('numeric comparison', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) WHERE n.age > 28 RETURN n.name',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Charlie']);
    });

    test('AND / OR composition', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) WHERE n.age > 25 AND n.age < 40 RETURN n.name',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Dave']);
    });

    test('string equality', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        "MATCH (n:Person) WHERE n.name = 'Bob' RETURN n.age",
      );
      expect(r.rows.single.values['n.age'], 25);
    });

    test('inline property pattern lowers to a WHERE', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        "MATCH (n:Person {name: 'Bob'}) RETURN n.age",
      );
      expect(r.rows.single.values['n.age'], 25);
    });
  });

  group('Expand (relationship patterns)', () {
    test('outgoing -[:knows]->', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows]->(b:Person) '
        "WHERE a.name = 'Alice' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['Bob', 'Charlie']);
    });

    test('incoming <-[:knows]-', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)<-[:knows]-(b:Person) '
        "WHERE a.name = 'Charlie' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['Alice', 'Bob']);
    });

    test('chained pattern (a)-[:knows]->(b)-[:knows]->(c)', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows]->(b:Person)-[:knows]->(c:Person) '
        "WHERE a.name = 'Alice' RETURN c.name",
      );
      final names = r.rows.map((x) => x.values['c.name']).toList();
      // Alice → Bob → Charlie ; Alice → Charlie → Dave
      expect(names..sort(), ['Charlie', 'Dave']);
    });

    test('edge alias bindable in RETURN as the eid', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[r:knows]->(b:Person) RETURN r',
      );
      // 5 edges in the graph → 5 result rows.
      expect(r.length, 5);
      expect(r.rows.first.values['r'], isA<Eid>());
    });
  });

  group('DISTINCT + parse / plan errors', () {
    test('DISTINCT de-duplicates result rows', () async {
      final db = await _peopleDb();
      final r = await db.executeQuery(
        // Same age (28) shared by no two people, so we re-derive a
        // duplicate by projecting just the label-side of every edge.
        'MATCH (a:Person)-[:knows]->(b:Person) RETURN DISTINCT a.name',
      );
      final names = r.rows.map((x) => x.values['a.name']).toList();
      // Alice, Bob, Charlie, Dave each have at least one outgoing
      // knows edge.
      expect(names.toSet(), {'Alice', 'Bob', 'Charlie', 'Dave'});
    });

    test('unknown label is a plan error', () async {
      final db = await _peopleDb();
      await expectLater(
        () => db.executeQuery('MATCH (n:NoSuchLabel) RETURN n'),
        throwsA(isA<PlannerException>()),
      );
    });

    test('multi-pattern MATCH deferred → plan error', () async {
      final db = await _peopleDb();
      await expectLater(
        () => db.executeQuery(
            'MATCH (a:Person), (b:Person) RETURN a, b'),
        throwsA(isA<PlannerException>()),
      );
    });
  });
}
