import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

/// Chain: 0 -[knows]-> 1 -[knows]-> 2 -[knows]-> 3 -[knows]-> 4
Future<GraphDb> _chainDb() async {
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
  for (var i = 0; i < 5; i++) {
    state.csr.labelOf[i] = personLabel;
    state.nodeProps.setString(i, nameKey, String.fromCharCode(0x41 + i));
  }
  await db.bulkAddEdges(
    const [
      BulkEdge(src: Vid(0), dst: Vid(1), typeId: 0),
      BulkEdge(src: Vid(1), dst: Vid(2), typeId: 0),
      BulkEdge(src: Vid(2), dst: Vid(3), typeId: 0),
      BulkEdge(src: Vid(3), dst: Vid(4), typeId: 0),
    ],
    durability: Durability.none,
  );
  return db;
}

void main() {
  group('variable-length paths (plan §8 / §14 Phase 3D)', () {
    test('*1..2 enumerates 1- and 2-hop reachable nodes', () async {
      final db = await _chainDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows*1..2]->(b:Person) '
        "WHERE a.name = 'A' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['B', 'C']);
    });

    test('*1..4 reaches every later node from A', () async {
      final db = await _chainDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows*1..4]->(b:Person) '
        "WHERE a.name = 'A' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['B', 'C', 'D', 'E']);
    });

    test('*2..2 returns only the exact 2-hop neighbours', () async {
      final db = await _chainDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows*2..2]->(b:Person) '
        "WHERE a.name = 'A' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names, ['C']);
    });

    test('* (unbounded, defaults to *1..) reaches every descendant', () async {
      final db = await _chainDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)-[:knows*]->(b:Person) '
        "WHERE a.name = 'A' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['B', 'C', 'D', 'E']);
    });

    test('incoming variable-length walks reverse direction', () async {
      final db = await _chainDb();
      final r = await db.executeQuery(
        'MATCH (a:Person)<-[:knows*1..2]-(b:Person) '
        "WHERE a.name = 'D' RETURN b.name",
      );
      final names = r.rows.map((x) => x.values['b.name']).toList();
      expect(names..sort(), ['B', 'C']);
    });
  });
}
