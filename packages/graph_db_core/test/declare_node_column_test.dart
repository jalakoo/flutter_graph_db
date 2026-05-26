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
  group('declareNodeColumn', () {
    test('reserves a typed column before any write', () {
      final db = _db();
      final k = db.internPropKey('score');
      expect(db.nodePropType(k), isNull); // no column yet
      db.declareNodeColumn(k, ColumnType.double_);
      expect(db.nodePropType(k), ColumnType.double_); // reserved ahead of data
    });

    test('re-declaring the same type is an idempotent no-op', () {
      final db = _db();
      final k = db.internPropKey('age');
      db.declareNodeColumn(k, ColumnType.int_);
      db.declareNodeColumn(k, ColumnType.int_); // no throw
      expect(db.nodePropType(k), ColumnType.int_);
    });

    test('re-declaring a conflicting type throws ConstraintViolation', () {
      final db = _db();
      final k = db.internPropKey('age');
      db.declareNodeColumn(k, ColumnType.int_);
      expect(
        () => db.declareNodeColumn(k, ColumnType.double_),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('a matching-typed write to a pre-declared column round-trips',
        () async {
      final db = _db();
      final n = db.internLabel('N');
      final k = db.internPropKey('score');
      db.declareNodeColumn(k, ColumnType.double_);
      final v = await db.runTransaction((txn) => txn.addNode(
            labelIds: [n],
            props: {k: const PropDouble(3.5)},
          ));
      expect(db.getNodeDoubleProp(v, k), 3.5);
    });
  });
}
