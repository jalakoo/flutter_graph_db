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
  group('GraphSchema.add — raw-value boxing', () {
    test('promotes an int into a declared double column (3 -> 3.0)', () async {
      final db = _db();
      final s = db.defineSchema(
        labels: {'Phrase'},
        propKeys: {'score': ColumnType.double_},
      );
      final v = await s.add('Phrase', {'score': 3});
      expect(db.getNodeDoubleProp(v, s.propKey('score')), 3.0);
    });

    test('a lossy double into an int column throws', () async {
      final db = _db();
      final s = db.defineSchema(
        labels: {'Phrase'},
        propKeys: {'order': ColumnType.int_},
      );
      await expectLater(s.add('Phrase', {'order': 3.5}), throwsArgumentError);
    });

    test('a type mismatch (String into a double column) throws', () async {
      final db = _db();
      final s = db.defineSchema(
        labels: {'Phrase'},
        propKeys: {'score': ColumnType.double_},
      );
      await expectLater(s.add('Phrase', {'score': 'high'}), throwsArgumentError);
    });

    test('an undeclared key is boxed strictly by its Dart type', () async {
      final db = _db();
      final s = db.defineSchema(labels: {'Phrase'});
      final v = await s.add('Phrase', {'count': 7}); // not declared
      final k = db.propKeyId('count')!;
      expect(db.nodePropType(k), ColumnType.int_); // column created at int
      expect(db.getNodeIntProp(v, k), 7);
    });

    test('a null value stores as PropNull (present but null)', () async {
      final db = _db();
      final s = db.defineSchema(
        labels: {'Phrase'},
        propKeys: {'name': ColumnType.string},
      );
      final v = await s.add('Phrase', {'name': null});
      final k = s.propKey('name');
      expect(db.hasNodeProp(v, k), isTrue);
      expect(db.nodePropIsNull(v, k), isTrue);
    });

    test('the node carries the declared label; mixed props round-trip',
        () async {
      final db = _db();
      final s = db.defineSchema(
        labels: {'Phrase'},
        propKeys: {'score': ColumnType.double_, 'name': ColumnType.string},
      );
      final v = await s.add('Phrase', {'name': 'hi', 'score': 2, 'tag': 'x'});
      expect(db.hasLabel(v, s.label('Phrase')), isTrue);
      expect(db.getNodeStringProp(v, s.propKey('name')), 'hi');
      expect(db.getNodeDoubleProp(v, s.propKey('score')), 2.0); // promoted
      expect(db.getNodeStringProp(v, db.propKeyId('tag')!), 'x'); // undeclared
    });

    test('an unsupported value type (List) throws', () async {
      final db = _db();
      final s = db.defineSchema(labels: {'Phrase'});
      await expectLater(
          s.add('Phrase', {'bad': [1, 2]}), throwsArgumentError);
    });
  });
}
