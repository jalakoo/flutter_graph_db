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
  group('in-transaction read guard', () {
    test('a read AFTER a write in the same txn throws a read-after-write error',
        () async {
      final db = _db();
      final n = db.internLabel('N');
      await expectLater(
        db.runTransaction((txn) {
          txn.addNode(labelIds: [n]); // write
          db.nodeCount; // read after the write — would be pre-write state
        }),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            allOf(contains('after a write'), contains('runTransaction')))),
      );
    });

    test('property reads inside a txn also throw', () async {
      final db = _db();
      final n = db.internLabel('N');
      final v = await db.runTransaction((txn) => txn.addNode(labelIds: [n]));
      await expectLater(
        db.runTransaction((txn) {
          txn.delNode(v);
          db.getNodeProp(v, 0);
        }),
        throwsStateError,
      );
    });

    test('reads before and after a txn are fine (read-your-writes)', () async {
      final db = _db();
      final n = db.internLabel('N');
      expect(db.nodeCount, 0); // before
      await db.runTransaction((txn) => txn.addNode(labelIds: [n]));
      expect(db.nodeCount, 1); // after — committed write is visible
      expect(db.labelScan(n).length, 1);
    });

    test('a read BEFORE any write in a txn returns committed-as-of-begin state',
        () async {
      final db = _db();
      final n = db.internLabel('N');
      await db.runTransaction((txn) => txn.addNode(labelIds: [n])); // commit 1

      await db.runTransaction((txn) {
        // Read issued before any mutation in this txn: returns the
        // committed-as-of-begin snapshot, no StateError.
        expect(db.nodeCount, 1);
        expect(db.labelScan(n).length, 1);
        txn.addNode(labelIds: [n]); // writing after the read is fine
      });

      expect(db.nodeCount, 2); // commit landed
    });
  });
}
