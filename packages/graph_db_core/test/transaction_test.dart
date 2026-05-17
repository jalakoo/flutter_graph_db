import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

GraphDb _small() {
  final state = MutableGraphState.fromFixture(
    nodeCount: 3,
    srcs: Uint32List.fromList([0, 1]),
    dsts: Uint32List.fromList([1, 2]),
    edgeTypes: Uint32List.fromList([0, 0]),
    labelOf: Uint32List(3),
    labelNames: const ['Node'],
    edgeTypeNames: const ['link'],
    vidSpace: 16,
    eidSpace: 16,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('commit semantics', () {
    test('mutations land after the closure returns', () async {
      final db = _small();
      final age = db.internPropKey('age');
      final v = await db.runTransaction((txn) {
        final v = txn.addNode(labelIds: [0], props: {
          age: const PropInt(30),
        });
        return v;
      });
      expect(db.state.isNodeVisible(v), isTrue);
      expect(db.state.nodeProps.getInt(v.value, age), 30);
    });

    test('returns the body value', () async {
      final db = _small();
      final answer = await db.runTransaction((txn) => 42);
      expect(answer, 42);
    });

    test('emits BeginTxn → ops → CommitTxn at sequential LSNs', () async {
      final db = _small();
      final lsnBefore = db.state.nextLsn;
      await db.runTransaction((txn) {
        txn.addNode(labelIds: [0]);
        txn.addNode(labelIds: [0]);
      });
      // 2 user ops + 1 BeginTxn + 1 CommitTxn = 4 LSNs consumed.
      expect(db.state.nextLsn, lsnBefore + 4);
    });

    test('empty transaction consumes no LSN + no txn id increment past one',
        () async {
      final db = _small();
      final lsnBefore = db.state.nextLsn;
      final txnBefore = db.state.nextTxnId;
      await db.runTransaction((txn) {
        // no ops
      });
      expect(db.state.nextLsn, lsnBefore);
      // txnId is consumed regardless — the allocator runs at entry.
      expect(db.state.nextTxnId, txnBefore + 1);
    });

    test('addNode + addEdge inside one txn link correctly', () async {
      final db = _small();
      late Eid eid;
      await db.runTransaction((txn) {
        final a = txn.addNode(labelIds: [0]);
        final b = txn.addNode(labelIds: [0]);
        eid = txn.addEdge(src: a, dst: b, typeId: 0);
      });
      final added = db.state.overlay.addedEdges[eid.value]!;
      expect(added.src, db.state.nextVid - 2);
      expect(added.dst, db.state.nextVid - 1);
    });
  });

  group('rollback semantics', () {
    test('throw inside the closure drops the buffer', () async {
      final db = _small();
      final lsnBefore = db.state.nextLsn;
      await expectLater(
        () => db.runTransaction((txn) {
          txn.addNode(labelIds: [0]);
          throw StateError('oops');
        }),
        throwsA(isA<StateError>()),
      );
      expect(db.state.nextLsn, lsnBefore);
    });

    test('allocated vid is not reused after rollback (plan §3.6)', () async {
      final db = _small();
      late Vid lost;
      try {
        await db.runTransaction((txn) {
          lost = txn.addNode(labelIds: [0]);
          throw StateError('rollback');
        });
      } catch (_) {/* expected */}
      final next = db.state.allocVid();
      expect(next.value, greaterThan(lost.value));
    });

    test('original state is unchanged', () async {
      final db = _small();
      final beforeNodeCount = db.state.overlay.addedNodes.length;
      try {
        await db.runTransaction((txn) {
          txn.addNode(labelIds: [0]);
          throw Exception('x');
        });
      } catch (_) {}
      expect(db.state.overlay.addedNodes.length, beforeNodeCount);
    });
  });

  group('lifecycle guards', () {
    test('nested runTransaction throws StateError', () async {
      final db = _small();
      await expectLater(
        () => db.runTransaction((outer) async {
          await db.runTransaction((inner) {});
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('using a terminated txn handle throws StateError', () async {
      final db = _small();
      late Transaction stash;
      await db.runTransaction((txn) {
        stash = txn;
      });
      expect(stash.isTerminated, isTrue);
      expect(
        () => stash.addNode(labelIds: [0]),
        throwsA(isA<StateError>()),
      );
    });

    test('activeTxnId reset after both commit and rollback', () async {
      final db = _small();
      await db.runTransaction((txn) {});
      expect(db.state.activeTxnId, isNull);
      try {
        await db.runTransaction((txn) => throw StateError('x'));
      } catch (_) {}
      expect(db.state.activeTxnId, isNull);
    });
  });

  group('full coverage of txn mutation API', () {
    test('every mutation method buffers + applies', () async {
      final db = _small();
      final age = db.internPropKey('age');
      final w = db.internPropKey('weight');
      final newLabel = db.internLabel('Vip');
      await db.runTransaction((txn) {
        final v = txn.addNode(labelIds: [0]);
        txn.setNodeProp(v, age, const PropInt(40));
        txn.setNodeLabels(v, added: [newLabel], removed: const [0]);
        final e = txn.addEdge(src: v, dst: const Vid(0), typeId: 0);
        txn.setEdgeProp(e, w, const PropDouble(2.5));
        txn.delEdgeProp(e, w);
        txn.delEdge(e);
        txn.delNodeProp(v, age);
      });
      // 1 BeginTxn + 8 user ops + 1 CommitTxn
      expect(db.state.nextLsn, 10);
    });
  });
}
