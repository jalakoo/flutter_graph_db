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
Future<({GraphDb db, MutableGraphState state})> _peopleDb() async {
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
    state.csr.labelOf[i] = personLabel;
    state.nodeProps.setString(i, nameKey, names[i]);
    state.nodeProps.setInt(i, ageKey, ages[i]);
  }
  // Rebuild labelIndex now that labelOf was patched (csr was built
  // with default label 0; we just confirmed it's the Person label).
  final lbl = state.csr.labelIndex[personLabel] ?? Uint32List(0);
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
  return (db: db, state: state);
}

void main() {
  group('NodeScan + Project', () {
    test('returns every Person', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery('MATCH (n:Person) RETURN n.name');
      expect(r.columns, ['n.name']);
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Bob', 'Charlie', 'Dave', 'Eve']);
    });

    test('RETURN with AS alias', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name AS who',
      );
      expect(r.columns, ['who']);
      expect(r.rows.first.values.keys, ['who']);
    });

    test('full scan (no label)', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery('MATCH (n) RETURN n.name');
      expect(r.length, 5);
    });
  });

  group('WHERE filtering', () {
    test('numeric comparison', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) WHERE n.age > 28 RETURN n.name',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Charlie']);
    });

    test('AND / OR composition', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) WHERE n.age > 25 AND n.age < 40 RETURN n.name',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names..sort(), ['Alice', 'Dave']);
    });

    test('string equality', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        "MATCH (n:Person) WHERE n.name = 'Bob' RETURN n.age",
      );
      expect(r.rows.single.values['n.age'], 25);
    });

    test('inline property pattern lowers to a WHERE', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        "MATCH (n:Person {name: 'Bob'}) RETURN n.age",
      );
      expect(r.rows.single.values['n.age'], 25);
    });
  });

  group('Expand (relationship patterns)', () {
    test('outgoing -[:knows]->', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows]->(b:Person) '
        "WHERE a.name = 'Alice' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['Bob', 'Charlie']);
    });

    test('incoming <-[:knows]-', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)<-[:knows]-(b:Person) '
        "WHERE a.name = 'Charlie' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['Alice', 'Bob']);
    });

    test('chained pattern (a)-[:knows]->(b)-[:knows]->(c)', () async {
      final (:db, state: _) = await _peopleDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows]->(b:Person)-[:knows]->(c:Person) '
        "WHERE a.name = 'Alice' RETURN c.name",
      );
      final names = r.rows.map((x) => x.values['c.name']).toList();
      // Alice → Bob → Charlie ; Alice → Charlie → Dave
      expect(names..sort(), ['Charlie', 'Dave']);
    });

    test('edge alias bindable in RETURN as the eid', () async {
      final (:db, state: _) = await _peopleDb();
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
      final (:db, state: _) = await _peopleDb();
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
      final (:db, state: _) = await _peopleDb();
      await expectLater(
        () => db.executeQuery('MATCH (n:NoSuchLabel) RETURN n'),
        throwsA(isA<PlannerException>()),
      );
    });

    test('multi-pattern MATCH deferred → plan error', () async {
      final (:db, state: _) = await _peopleDb();
      await expectLater(
        () => db.executeQuery(
            'MATCH (a:Person), (b:Person) RETURN a, b'),
        throwsA(isA<PlannerException>()),
      );
    });
  });

  // ----- Multi-label rollout PR 3: GQL surface -----

  group('multi-label patterns + functions (PR 3)', () {
    test('(:A:B) AND-matches only nodes carrying both labels', () async {
      final (:db, :state) = await _peopleDb();
      final employeeLabel = db.internLabel('Employee');
      await db.runTransaction((txn) {
        txn.setNodeLabels(const Vid(0),
            added: [employeeLabel], removed: const []);
      });
      state.mergeNow();

      final both = await db.executeQuery(
        'MATCH (n:Person:Employee) RETURN n.name',
      );
      expect(
        both.rows.map((r) => r.values['n.name']).toList(),
        ['Alice'],
        reason: 'only vid 0 carries both Person and Employee',
      );

      final justPerson = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name',
      );
      expect(justPerson.rows.length, 5);
    });

    test('labels(n) returns sorted-ascending list of label names',
        () async {
      final (:db, :state) = await _peopleDb();
      final employeeLabel = db.internLabel('Employee');
      await db.runTransaction((txn) {
        txn.setNodeLabels(const Vid(0),
            added: [employeeLabel], removed: const []);
      });
      state.mergeNow();

      final r = await db.executeQuery(
        "MATCH (n:Person) WHERE n.name = 'Alice' RETURN labels(n) AS ls",
      );
      expect(r.rows.length, 1);
      final ls = r.rows.single.values['ls'] as List;
      // Sorted ascending by string per §19.5 — Employee < Person.
      expect(ls, ['Employee', 'Person']);
    });

    test('CREATE (n:A:B) lands both labels', () async {
      final (:db, :state) = await _peopleDb();
      db.internLabel('Tagged');
      db.internLabel('Person');
      await db.executeQuery(
        "CREATE (n:Person:Tagged {name: 'multi'})",
      );
      state.mergeNow();
      final r = await db.executeQuery(
        "MATCH (n:Person:Tagged) RETURN labels(n) AS ls",
      );
      expect(r.rows.length, 1);
      expect(
        (r.rows.single.values['ls'] as List).cast<String>(),
        ['Person', 'Tagged'],
      );
    });
  });

  group('PlannerDiagnostic — node.label deprecation (PR 3 / §19.10.2)', () {
    test('reading n.label inside RETURN fires a warning', () async {
      final (:db, state: _) = await _peopleDb();
      final diags = <PlannerDiagnostic>[];
      db.onPlannerDiagnostic = diags.add;
      try {
        await db.executeQuery('MATCH (n:Person) RETURN n.label AS l');
      } catch (_) {
        // Execution may or may not reject the changed shape; the
        // diagnostic must fire at plan-build time regardless.
      }
      expect(diags.length, greaterThanOrEqualTo(1));
      final warn = diags.firstWhere(
        (d) => d.message.contains('n.label'),
        orElse: () => throw StateError('no n.label diagnostic'),
      );
      expect(warn.severity, PlannerDiagnosticSeverity.warning);
      expect(warn.hint, contains('labels(n)'));
    });

    test('default listener is silent (no listener set)', () async {
      final (:db, state: _) = await _peopleDb();
      try {
        await db.executeQuery('MATCH (n:Person) RETURN n.name');
      } catch (e) {
        fail('default path should not throw, got $e');
      }
    });
  });
}
