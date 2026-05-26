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
  group('defineSchema / GraphSchema', () {
    test('interns labels and returns stable, engine-consistent handles', () {
      final db = _db();
      final s = db.defineSchema(labels: {'Phrase', 'Context'});
      expect(s.label('Phrase'), db.internLabel('Phrase')); // same interned id
      expect(s.label('Context'), db.internLabel('Context'));
      expect(s.label('Phrase'), s.label('Phrase')); // stable across calls
    });

    test('typed propKeys reserve their columns eagerly (before any write)', () {
      final db = _db();
      final s = db.defineSchema(propKeys: {
        'score': ColumnType.double_,
        'order': ColumnType.int_,
      });
      expect(db.nodePropType(s.propKey('score')), ColumnType.double_);
      expect(db.nodePropType(s.propKey('order')), ColumnType.int_);
    });

    test('edge types are interned and resolvable', () {
      final db = _db();
      final s = db.defineSchema(edgeTypes: {'IN_CONTEXT', 'RELATES_TO'});
      expect(s.edgeType('IN_CONTEXT'), db.internEdgeType('IN_CONTEXT'));
      expect(s.edgeType('RELATES_TO'), db.internEdgeType('RELATES_TO'));
    });

    test('looking up a name that was not declared throws ArgumentError', () {
      final db = _db();
      final s = db.defineSchema(labels: {'Phrase'});
      expect(() => s.label('Context'), throwsArgumentError);
      expect(() => s.propKey('name'), throwsArgumentError);
      expect(() => s.edgeType('IN_CONTEXT'), throwsArgumentError);
    });

    test('re-declaring matches no-op; a conflicting type fails fast', () {
      final db = _db();
      db.defineSchema(propKeys: {'score': ColumnType.double_});
      // Same type again — no-op (the every-open re-declare case).
      expect(() => db.defineSchema(propKeys: {'score': ColumnType.double_}),
          returnsNormally);
      // Conflicting type — recovery fail-fast.
      expect(() => db.defineSchema(propKeys: {'score': ColumnType.int_}),
          throwsA(isA<ConstraintViolation>()));
    });
  });
}
