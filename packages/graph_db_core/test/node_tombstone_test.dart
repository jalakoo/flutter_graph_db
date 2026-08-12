import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// A node delete must survive an overlay merge and a snapshot round-trip.
///
/// Regression: `Csr` carried no tombstone field. `foldOverlayIntoCsr`
/// built a tombstone bitmap, `Csr.fromEdges` used it only to filter
/// `labelIndex` and then dropped it, and `installMergedCsr` cleared the
/// overlay that held the delete. After a merge the vid became visible
/// again — `isNodeVisible` returned true, `scanNodes` (so GQL
/// `MATCH (n)`) yielded a phantom row, and edges/props could be written
/// to the dead node.

GraphDb _db() => GraphDb.fromState(MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const ['Person'],
      edgeTypeNames: const ['KNOWS'],
      vidSpace: 16,
      eidSpace: 16,
    ));

void main() {
  group('node tombstones survive a merge', () {
    late GraphDb db;
    late int person;
    late int name;
    late Vid dead;
    late Vid live;

    setUp(() async {
      db = _db();
      person = db.internLabel('Person');
      name = db.internPropKey('name');
      dead = await db.runTransaction((t) =>
          t.addNode(labelIds: [person], props: {name: const PropString('A')}));
      live = await db.runTransaction((t) =>
          t.addNode(labelIds: [person], props: {name: const PropString('B')}));
      await db.runTransaction((t) => t.delNode(dead));
    });

    test('isNodeVisible stays false across mergeNow', () {
      expect(db.isNodeVisible(dead), isFalse, reason: 'before merge');
      expect(db.isNodeVisible(live), isTrue);
      db.mergeNow();
      expect(db.isNodeVisible(dead), isFalse, reason: 'after merge');
      expect(db.isNodeVisible(live), isTrue);
    });

    test('scanNodes omits the deleted vid across mergeNow', () {
      expect(db.readView.scanNodes().map((v) => v.value), [live.value]);
      db.mergeNow();
      expect(db.readView.scanNodes().map((v) => v.value), [live.value]);
    });

    test('labelScan omits the deleted vid across mergeNow', () {
      expect(db.labelScan(person), [live.value]);
      db.mergeNow();
      expect(db.labelScan(person), [live.value]);
    });

    test('a second merge does not resurrect an earlier delete', () async {
      db.mergeNow();
      // A fresh generation of writes, then another fold. The base
      // tombstones must be unioned forward, not replaced.
      final third = await db.runTransaction((t) =>
          t.addNode(labelIds: [person], props: {name: const PropString('C')}));
      db.mergeNow();
      expect(db.isNodeVisible(dead), isFalse);
      expect(db.isNodeVisible(live), isTrue);
      expect(db.isNodeVisible(third), isTrue);
      expect(db.labelScan(person), [live.value, third.value]);
    });

    test('addEdge to a merged-away node is rejected', () async {
      db.mergeNow();
      final knows = db.internEdgeType('KNOWS');
      await expectLater(
        db.runTransaction((t) => t.addEdge(src: live, dst: dead, typeId: knows)),
        throwsA(isA<NotFoundException>()),
      );
      expect(db.edgeCount, 0);
    });

    test('setNodeProp on a merged-away node is rejected', () async {
      db.mergeNow();
      await expectLater(
        db.runTransaction(
            (t) => t.setNodeProp(dead, name, const PropString('zombie'))),
        throwsA(isA<NotFoundException>()),
      );
    });

    // Replay paths (recovery, sync) are the only callers that pass an
    // explicit vid to `applyAddNode`, so this exercises the state
    // directly rather than through a transaction.
    test('re-adding a merged-away vid is rejected', () {
      final state = MutableGraphState.fromFixture(
        nodeCount: 0,
        srcs: Uint32List(0),
        dsts: Uint32List(0),
        edgeTypes: Uint32List(0),
        labelOf: Uint32List(0),
        labelNames: const ['Person'],
        edgeTypeNames: const [],
        vidSpace: 16,
        eidSpace: 16,
      );
      final l = state.strings.internLabel('Person');
      final v = state.allocVid();
      state.applyAddNode(v, logicalId: 'x', labelIds: [l], props: const {});
      state.applyDelNode(v);
      state.mergeNow();
      expect(
        () => state.applyAddNode(v, logicalId: 'y', labelIds: [l], props: const {}),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('deleted node stays deleted through a snapshot round-trip', () {
      db.mergeNow();
      final snap = db.captureSnapshot();
      final restored = decodeSnapshot(snap.bytes);
      expect(restored.isNodeVisible(dead), isFalse);
      expect(restored.isNodeVisible(live), isTrue);
      expect(restored.scanNodes().map((v) => v.value), [live.value]);
      expect(restored.effectiveLabelScan(person), [live.value]);
    });

    test('incident edges of a deleted node do not survive the fold', () async {
      final knows = db.internEdgeType('KNOWS');
      final other = await db.runTransaction((t) =>
          t.addNode(labelIds: [person], props: {name: const PropString('D')}));
      await db.runTransaction((t) => t.addEdge(
          src: live, dst: other, typeId: knows));
      expect(db.edgeCount, 1);
      await db.runTransaction((t) => t.delNode(other));
      expect(db.edgeCount, 0);
      db.mergeNow();
      expect(db.edgeCount, 0);
      expect(db.outDegree(live), 0);
      expect(db.isNodeVisible(other), isFalse);
    });
  });

  test('Csr.isTombstoned / tombstoneCount reflect the bitmap', () {
    final tombstones = Uint8List.fromList([0, 1, 0]);
    final csr = Csr.fromEdges(
      nodeCount: 3,
      srcs: Uint32List.fromList([0]),
      dsts: Uint32List.fromList([2]),
      edgeTypes: Uint32List.fromList([0]),
      labelOf: Uint32List.fromList([0, 0, 0]),
      labelCount: 1,
      nodeTombstones: tombstones,
    );
    expect(csr.isTombstoned(0), isFalse);
    expect(csr.isTombstoned(1), isTrue);
    expect(csr.isTombstoned(2), isFalse);
    expect(csr.tombstoneCount, 1);
    expect(csr.labelIndex[0], [0, 2]);
  });

  test('Csr with no deletes keeps a null tombstone array', () {
    final csr = Csr.fromEdges(
      nodeCount: 2,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List.fromList([0, 0]),
      labelCount: 1,
    );
    expect(csr.nodeTombstones, isNull);
    expect(csr.isTombstoned(0), isFalse);
    expect(csr.tombstoneCount, 0);
  });
}
