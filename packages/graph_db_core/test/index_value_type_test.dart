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
      vidSpace: 64,
      eidSpace: 64,
    ));

void main() {
  group('IndexSpec.valueType — index an empty graph', () {
    test('builds an empty index when no column exists yet', () {
      final db = _db();
      final extId = db.internPropKey('extId');
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'extId',
        keyId: extId,
        kind: const EqualityRange(unique: true, hashOverlay: true),
        valueType: ColumnType.string,
      ));
      expect(idx.length, 0);
      expect(db.getNodeIndex('extId'), isNotNull);
    });

    test('the empty index populates as writes arrive', () async {
      final db = _db();
      final n = db.internLabel('N');
      final extId = db.internPropKey('extId');
      db.createNodePropertyIndex(IndexSpec(
        name: 'extId',
        keyId: extId,
        kind: const EqualityRange(unique: true, hashOverlay: true),
        valueType: ColumnType.string,
      ));

      final a = await db.runTransaction((txn) =>
          txn.addNode(labelIds: [n], props: {extId: const PropString('x1')}));

      final idx = db.getNodeIndex('extId')!;
      expect(idx.length, 1);
      expect(idx.vidAt(0), a.value);
    });

    test('without valueType, indexing an empty graph still throws', () {
      final db = _db();
      final extId = db.internPropKey('extId');
      expect(
        () => db.createNodePropertyIndex(IndexSpec(
            name: 'extId', keyId: extId, kind: const EqualityRange())),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('valueType conflicting with an existing column is rejected',
        () async {
      final db = _db();
      final n = db.internLabel('N');
      final age = db.internPropKey('age');
      await db.runTransaction(
          (txn) => txn.addNode(labelIds: [n], props: {age: const PropInt(30)}));
      expect(
        () => db.createNodePropertyIndex(IndexSpec(
            name: 'age',
            keyId: age,
            kind: const EqualityRange(),
            valueType: ColumnType.string)),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('a mismatched-type write to a valueType-locked column is rejected',
        () async {
      final db = _db();
      final n = db.internLabel('N');
      final extId = db.internPropKey('extId');
      db.createNodePropertyIndex(IndexSpec(
        name: 'extId',
        keyId: extId,
        kind: const EqualityRange(unique: true),
        valueType: ColumnType.string,
      ));
      // The column is locked to string by the index declaration.
      await expectLater(
        db.runTransaction((txn) =>
            txn.addNode(labelIds: [n], props: {extId: const PropInt(7)})),
        throwsA(isA<ConstraintViolation>()),
      );
    });
  });
}
