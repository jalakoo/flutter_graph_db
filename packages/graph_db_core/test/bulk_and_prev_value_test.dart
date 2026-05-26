import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

({GraphDb db, MutableGraphState state}) _seedDb({int nodeCount = 10}) {
  final state = MutableGraphState.fromFixture(
    nodeCount: nodeCount,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(nodeCount),
    labelNames: const ['Node'],
    edgeTypeNames: const ['link'],
    vidSpace: nodeCount + 16,
    eidSpace: 16,
  );
  return (db: GraphDb.fromState(state), state: state);
}

void main() {
  group('bulkAddEdges (plan §14 Phase 2F)', () {
    test('inserts edges directly into CSR — no overlay overhead', () async {
      final (:db, :state) = _seedDb(nodeCount: 5);
      final eids = await db.bulkAddEdges([
        BulkEdge(src: const Vid(0), dst: const Vid(1), typeId: 0),
        BulkEdge(src: const Vid(1), dst: const Vid(2), typeId: 0),
        BulkEdge(src: const Vid(2), dst: const Vid(3), typeId: 0),
      ]);
      expect(eids.length, 3);
      // Overlay stays empty — the bulk path bypassed it.
      expect(state.overlay.isEmpty, isTrue);
      // The new CSR has 3 edges + matching structure.
      expect(state.csr.edgeCount, 3);
      expect(state.csr.outDegree(0), 1);
      expect(state.csr.outDegree(1), 1);
    });

    test('preserves prior overlay by merging it first', () async {
      final (:db, :state) = _seedDb(nodeCount: 5);
      // Land one regular-path edge in the overlay.
      await db.runTransaction((txn) {
        txn.addEdge(src: const Vid(0), dst: const Vid(4), typeId: 0);
      });
      expect(state.overlay.addedEdges.length, 1);
      // Bulk add another batch.
      await db.bulkAddEdges([
        BulkEdge(src: const Vid(1), dst: const Vid(2), typeId: 0),
        BulkEdge(src: const Vid(2), dst: const Vid(3), typeId: 0),
      ]);
      // All edges visible; overlay drained.
      expect(state.csr.edgeCount, 3);
      expect(state.overlay.isEmpty, isTrue);
    });

    test('returns allocated eids in input order', () async {
      final db = _seedDb(nodeCount: 5).db;
      final eids = await db.bulkAddEdges([
        BulkEdge(src: const Vid(0), dst: const Vid(1), typeId: 0),
        BulkEdge(src: const Vid(0), dst: const Vid(2), typeId: 0),
        BulkEdge(src: const Vid(0), dst: const Vid(3), typeId: 0),
      ]);
      // Monotonically increasing.
      for (var i = 1; i < eids.length; i++) {
        expect(eids[i].value, greaterThan(eids[i - 1].value));
      }
    });

    test('rejects edges with unknown endpoints', () async {
      final db = _seedDb(nodeCount: 5).db;
      await expectLater(
        () => db.bulkAddEdges([
          BulkEdge(src: const Vid(0), dst: const Vid(99), typeId: 0),
        ]),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('empty batch is a no-op', () async {
      final db = _seedDb().db;
      final eids = await db.bulkAddEdges(const []);
      expect(eids, isEmpty);
    });

    test('throws if a txn is in flight (single-writer guard)', () async {
      final db = _seedDb().db;
      await expectLater(
        () => db.runTransaction((txn) async {
          await db.bulkAddEdges([
            BulkEdge(src: const Vid(0), dst: const Vid(1), typeId: 0),
          ]);
        }),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('prevValue auto-capture (plan §6.4 / §14 Phase 2F)', () {
    test('capturePrevValues: false (default) leaves prevValue null', () async {
      final (:db, :state) = _seedDb();
      final age = db.internPropKey('age');
      state.nodeProps.setInt(0, age, 30);
      WalOp? captured;
      await db.runTransaction((txn) {
        txn.setNodeProp(const Vid(0), age, const PropInt(31));
        captured = txn.bufferedOps.single;
      });
      expect((captured as SetNodeProp).prevValue, isNull);
    });

    test('capturePrevValues: true captures the pre-write value', () async {
      final (:db, :state) = _seedDb();
      final age = db.internPropKey('age');
      state.nodeProps.setInt(0, age, 30);
      WalOp? captured;
      await db.runTransaction(
        (txn) {
          txn.setNodeProp(const Vid(0), age, const PropInt(31));
          captured = txn.bufferedOps.single;
        },
        capturePrevValues: true,
      );
      expect((captured as SetNodeProp).prevValue, const PropInt(30));
    });

    test('explicit prevValue arg wins over auto-capture', () async {
      final (:db, :state) = _seedDb();
      final age = db.internPropKey('age');
      state.nodeProps.setInt(0, age, 30);
      WalOp? captured;
      await db.runTransaction(
        (txn) {
          txn.setNodeProp(
            const Vid(0),
            age,
            const PropInt(31),
            prevValue: const PropInt(999), // explicit override
          );
          captured = txn.bufferedOps.single;
        },
        capturePrevValues: true,
      );
      expect((captured as SetNodeProp).prevValue, const PropInt(999));
    });

    test('edge variant also captures', () async {
      final (:db, :state) = _seedDb();
      // Need an edge to exist — bulk-add one first.
      await db.bulkAddEdges([
        BulkEdge(src: const Vid(0), dst: const Vid(1), typeId: 0),
      ]);
      final w = db.internPropKey('weight');
      state.edgeProps.setDouble(0, w, 1.5);
      WalOp? captured;
      await db.runTransaction(
        (txn) {
          txn.setEdgeProp(const Eid(0), w, const PropDouble(2.5));
          captured = txn.bufferedOps.single;
        },
        capturePrevValues: true,
      );
      expect((captured as SetEdgeProp).prevValue, const PropDouble(1.5));
    });
  });
}
