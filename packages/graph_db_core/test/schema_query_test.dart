import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

GraphDb _db() => GraphDb.fromState(MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const ['N'],
      edgeTypeNames: const ['rel'],
      vidSpace: 16,
      eidSpace: 16,
    ));

void main() {
  group('GraphSchema.find', () {
    test('matches by raw value, coercing the query like the write', () async {
      final db = _db();
      final s = db.defineSchema(
        labels: {'Phrase'},
        propKeys: {'score': ColumnType.double_},
      );
      final v = await s.add('Phrase', {'score': 3}); // stored as 3.0
      expect(s.find('score', 3), v); // raw int query coerced to 3.0 → matches
    });

    test('findAll returns all matches; find scopes by label', () async {
      final db = _db();
      final s = db.defineSchema(
        labels: {'Phrase', 'Context'},
        propKeys: {'name': ColumnType.string},
      );
      final p = await s.add('Phrase', {'name': 'hi'});
      final c = await s.add('Context', {'name': 'hi'}); // same name, diff label
      expect(s.findAll('name', 'hi').toSet(), {p, c});
      expect(s.find('name', 'hi', label: 'Phrase'), p); // label-scoped
      expect(s.find('name', 'hi', label: 'Context'), c);
    });

    test('returns null/empty for a property key that was never used', () {
      final db = _db();
      final s = db.defineSchema(labels: {'Phrase'});
      expect(s.find('ghost', 'x'), isNull);
      expect(s.findAll('ghost', 'x'), isEmpty);
    });
  });

  group('GraphSchema.outNeighbors / inNeighbors', () {
    test('filter neighbours by edge type, both directions', () async {
      final db = _db();
      final s = db.defineSchema(labels: {'P'}, edgeTypes: {'KNOWS', 'OTHER'});
      late Vid a, b, c;
      await db.runTransaction((tx) {
        a = tx.addNode(labelIds: [s.label('P')]);
        b = tx.addNode(labelIds: [s.label('P')]);
        c = tx.addNode(labelIds: [s.label('P')]);
        tx.addEdge(src: a, dst: b, typeId: s.edgeType('KNOWS'));
        tx.addEdge(src: a, dst: c, typeId: s.edgeType('OTHER'));
      });
      expect(s.outNeighbors(a, 'KNOWS'), [b]); // OTHER edge excluded
      expect(s.outNeighbors(a, 'OTHER'), [c]);
      expect(s.inNeighbors(b, 'KNOWS'), [a]);
      expect(s.inNeighbors(c, 'KNOWS'), isEmpty);
    });
  });
}
