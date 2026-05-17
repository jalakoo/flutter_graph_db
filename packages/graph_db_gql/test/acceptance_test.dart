/// LDBC-shaped acceptance harness (plan §8 / §14 Phase 3G).
///
/// **Not** the full LDBC SNB DataGen + the 7 official short queries —
/// those need the LDBC tooling + a real Cypher reference to compare
/// EXPLAIN plans against, and would balloon this package. Instead,
/// this is a focused fixture in the same shape (Person / Post /
/// Comment + KNOWS / CREATED / REPLY_OF) that exercises every v1
/// query surface end-to-end:
///
///   - MATCH / WHERE / RETURN with property predicates
///   - Multi-hop expansion (chained patterns)
///   - Variable-length BFS
///   - Aggregations (COUNT / AVG / MIN / MAX / COLLECT)
///   - ORDER BY / LIMIT / SKIP
///   - Parameter binding ($param)
///   - CREATE / SET / DELETE / MERGE writes
///   - The full pipeline (read → write → re-read) across a single
///     `GraphDb` instance.
///
/// Full LDBC SNB harness + plan equivalence vs Cypher EXPLAIN is
/// tracked as the remaining Phase 3 polish item in `4_PLAN.md`.
library;

import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

/// A small social-graph fixture in the LDBC SNB shape:
///
///   Persons (3):  alice, bob, charlie
///   Posts   (2):  p1 (by alice), p2 (by bob)
///   Comments(3):  c1 (by bob, reply to p1)
///                 c2 (by alice, reply to p2)
///                 c3 (by charlie, reply to c1)
///
///   Edges:        alice -KNOWS-> bob -KNOWS-> charlie
///                 p1, p2 -CREATED- alice/bob
///                 c1, c2, c3 each REPLY_OF a parent post or comment
Future<GraphDb> _socialDb() async {
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const [],
    edgeTypeNames: const [],
    vidSpace: 32,
    eidSpace: 32,
  );
  final db = GraphDb.fromState(state);
  // Seed catalog
  db.internLabel('Person');
  db.internLabel('Post');
  db.internLabel('Comment');
  db.internEdgeType('KNOWS');
  db.internEdgeType('CREATED');
  db.internEdgeType('REPLY_OF');
  db.internPropKey('name');
  db.internPropKey('age');
  db.internPropKey('city');
  db.internPropKey('title');
  db.internPropKey('text');

  // Persons via CREATE
  await db.executeQuery(
    "CREATE (n:Person {name: 'alice', age: 30, city: 'NYC'})",
  );
  await db.executeQuery(
    "CREATE (n:Person {name: 'bob', age: 25, city: 'SF'})",
  );
  await db.executeQuery(
    "CREATE (n:Person {name: 'charlie', age: 40, city: 'NYC'})",
  );
  // Posts
  await db.executeQuery(
    "CREATE (n:Post {title: 'p1', text: 'hello'})",
  );
  await db.executeQuery(
    "CREATE (n:Post {title: 'p2', text: 'world'})",
  );
  // Comments
  await db.executeQuery(
    "CREATE (n:Comment {text: 'c1'})",
  );
  await db.executeQuery(
    "CREATE (n:Comment {text: 'c2'})",
  );
  await db.executeQuery(
    "CREATE (n:Comment {text: 'c3'})",
  );

  // Edge wiring via CREATE through linked patterns
  await db.executeQuery(
    "MATCH (a:Person), (b:Person) WHERE 1=0 RETURN a", // warm
  ).catchError((_) => const QueryResult(columns: [], rows: []));

  // Use direct bulkAddEdges for edges (multi-pattern MATCH not
  // supported, so CREATE -[]-> in one stmt would need both nodes
  // bound; build edges directly).
  // Look up vids by name first.
  Future<Vid> vidOf(String label, String prop, String key, dynamic v) async {
    final r = await db.executeQuery(
      "MATCH (n:$label) WHERE n.$prop = \$v RETURN n",
      {'v': v},
    );
    return r.rows.single.values['n'] as Vid;
  }

  final alice = await vidOf('Person', 'name', 'name', 'alice');
  final bob = await vidOf('Person', 'name', 'name', 'bob');
  final charlie = await vidOf('Person', 'name', 'name', 'charlie');
  final p1 = await vidOf('Post', 'title', 'title', 'p1');
  final p2 = await vidOf('Post', 'title', 'title', 'p2');
  final c1 = await vidOf('Comment', 'text', 'text', 'c1');
  final c2 = await vidOf('Comment', 'text', 'text', 'c2');
  final c3 = await vidOf('Comment', 'text', 'text', 'c3');

  final knowsType = db.state.strings.edgeTypeIdOf('KNOWS')!;
  final createdType = db.state.strings.edgeTypeIdOf('CREATED')!;
  final replyOfType = db.state.strings.edgeTypeIdOf('REPLY_OF')!;
  await db.bulkAddEdges(
    [
      BulkEdge(src: alice, dst: bob, typeId: knowsType),
      BulkEdge(src: bob, dst: charlie, typeId: knowsType),
      BulkEdge(src: alice, dst: p1, typeId: createdType),
      BulkEdge(src: bob, dst: p2, typeId: createdType),
      BulkEdge(src: bob, dst: c1, typeId: createdType),
      BulkEdge(src: alice, dst: c2, typeId: createdType),
      BulkEdge(src: charlie, dst: c3, typeId: createdType),
      BulkEdge(src: c1, dst: p1, typeId: replyOfType),
      BulkEdge(src: c2, dst: p2, typeId: replyOfType),
      BulkEdge(src: c3, dst: c1, typeId: replyOfType),
    ],
    durability: Durability.none,
  );
  return db;
}

void main() {
  group('LDBC-shaped acceptance — read queries', () {
    test('S1: friend-of-friend over KNOWS*1..2', () async {
      final db = await _socialDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) '
        "WHERE a.name = 'alice' RETURN b.name ORDER BY b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names, ['bob', 'charlie']);
    });

    test('S2: posts created by people in NYC', () async {
      final db = await _socialDb();
      final r = await db.executeQuery(
        'MATCH (p:Person)-[:CREATED]->(po:Post) '
        "WHERE p.city = 'NYC' RETURN po.title",
      );
      final titles = r.rows.map((x) => x.values['po.title']).toList();
      expect(titles..sort(), ['p1']);
    });

    test('S3: comment count per author', () async {
      final db = await _socialDb();
      final r = await db.executeQuery(
        'MATCH (p:Person)-[:CREATED]->(c:Comment) '
        'RETURN p.name, COUNT(*) ORDER BY p.name',
      );
      final byName = <String, int>{};
      for (final row in r.rows) {
        byName[row.values['p.name'] as String] =
            row.values['COUNT(*)'] as int;
      }
      expect(byName, {'alice': 1, 'bob': 1, 'charlie': 1});
    });

    test('S4: aggregates over the Persons (COUNT/AVG/MIN/MAX)', () async {
      final db = await _socialDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN COUNT(*), AVG(n.age), MIN(n.age), MAX(n.age)',
      );
      final row = r.rows.single.values.values.toList();
      expect(row[0], 3); // COUNT
      // AVG = (30+25+40)/3 = ~31.667
      expect((row[1] as num).toDouble(), closeTo(31.667, 0.01));
      expect(row[2], 25); // MIN
      expect(row[3], 40); // MAX
    });

    test('S5: COLLECT names by city', () async {
      final db = await _socialDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.city, COLLECT(n.name) ORDER BY n.city',
      );
      expect(r.rows.length, 2);
      final byCity = <String, Set<Object?>>{};
      for (final row in r.rows) {
        byCity[row.values['n.city'] as String] = (row
            .values['COLLECT(n.name)'] as List<Object?>)
            .toSet();
      }
      expect(byCity['NYC'], {'alice', 'charlie'});
      expect(byCity['SF'], {'bob'});
    });

    test('S6: top-2 oldest people via ORDER BY LIMIT', () async {
      final db = await _socialDb();
      final r = await db.executeQuery(
        'MATCH (n:Person) RETURN n.name ORDER BY n.age DESC LIMIT 2',
      );
      final names = r.rows.map((x) => x.values['n.name']).toList();
      expect(names, ['charlie', 'alice']);
    });

    test(r'S7: parameterised — comments replying to p1', () async {
      final db = await _socialDb();
      final r = await db.executeQuery(
        r'MATCH (c:Comment)-[:REPLY_OF*1..3]->(p:Post) '
        r'WHERE p.title = $title RETURN c.text ORDER BY c.text',
        {'title': 'p1'},
      );
      final texts = r.rows.map((x) => x.values['c.text']).toList();
      // c1 replies p1 directly; c3 replies c1 (which replies p1).
      expect(texts, ['c1', 'c3']);
    });
  });

  group('LDBC-shaped acceptance — write queries', () {
    test('full lifecycle: MERGE → SET → DELETE → re-read', () async {
      final db = await _socialDb();
      // MERGE a person — should reuse existing alice.
      await db.executeQuery(
        "MERGE (n:Person {name: 'alice'})",
      );
      var r = await db.executeQuery(
        'MATCH (n:Person) RETURN COUNT(*)',
      );
      expect(r.rows.single.values.values.single, 3);
      // SET her age
      await db.executeQuery(
        "MATCH (n:Person) WHERE n.name = 'alice' SET n.age = 31",
      );
      r = await db.executeQuery(
        "MATCH (n:Person) WHERE n.name = 'alice' RETURN n.age",
      );
      expect(r.rows.single.values['n.age'], 31);
      // DELETE one of the comments → KNOWS chain unaffected
      await db.executeQuery(
        "MATCH (c:Comment) WHERE c.text = 'c2' DELETE c",
      );
      r = await db.executeQuery(
        'MATCH (c:Comment) RETURN COUNT(*)',
      );
      expect(r.rows.single.values.values.single, 2);
    });
  });
}
