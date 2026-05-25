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
  group('logical-id index', () {
    test('auto + explicit logicalId resolve both ways (RYW)', () async {
      final db = _db();
      final n = db.internLabel('N');
      final a = await db.runTransaction((txn) => txn.addNode(labelIds: [n]));
      final b = await db.runTransaction(
          (txn) => txn.addNode(labelIds: [n], logicalId: 'ext-b'));

      // Auto-assigned UUIDv7 round-trips.
      final aId = db.getNodeLogicalId(a);
      expect(aId, isNotNull);
      expect(db.nodeByLogicalId(aId!)?.value, a.value);

      // Explicit id round-trips.
      expect(db.getNodeLogicalId(b), 'ext-b');
      expect(db.nodeByLogicalId('ext-b')?.value, b.value);
      expect(db.nodeByLogicalId('missing'), isNull);
    });

    test('a duplicate logicalId is rejected', () async {
      final db = _db();
      final n = db.internLabel('N');
      await db.runTransaction(
          (txn) => txn.addNode(labelIds: [n], logicalId: 'dup'));
      await expectLater(
        db.runTransaction(
            (txn) => txn.addNode(labelIds: [n], logicalId: 'dup')),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('delete removes the node from the index', () async {
      final db = _db();
      final n = db.internLabel('N');
      final a = await db.runTransaction(
          (txn) => txn.addNode(labelIds: [n], logicalId: 'gone'));
      expect(db.nodeByLogicalId('gone')?.value, a.value);

      await db.runTransaction((txn) => txn.delNode(a));
      expect(db.nodeByLogicalId('gone'), isNull);
      expect(db.getNodeLogicalId(a), isNull);
    });

    test('survives a snapshot encode/decode round-trip', () async {
      final db = _db();
      final n = db.internLabel('N');
      final a = await db.runTransaction(
          (txn) => txn.addNode(labelIds: [n], logicalId: 'ext-a'));
      db.state.mergeNow(); // encodeSnapshot needs an empty overlay

      final restored = GraphDb.fromState(decodeSnapshot(encodeSnapshot(db.state).bytes));
      expect(restored.nodeByLogicalId('ext-a')?.value, a.value);
      expect(restored.getNodeLogicalId(a), 'ext-a');
    });
  });
}
