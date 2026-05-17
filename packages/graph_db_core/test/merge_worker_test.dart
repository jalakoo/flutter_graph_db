@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

MutableGraphState _baseline() => MutableGraphState.fromFixture(
      nodeCount: 5,
      srcs: Uint32List.fromList([0, 1, 2, 3]),
      dsts: Uint32List.fromList([1, 2, 3, 4]),
      edgeTypes: Uint32List.fromList([0, 0, 0, 0]),
      labelOf: Uint32List(5),
      labelNames: const ['Node'],
      edgeTypeNames: const ['link'],
      vidSpace: 32,
      eidSpace: 32,
    );

void main() {
  group('MergeCoordinator (worker isolate)', () {
    late MergeCoordinator coord;

    setUpAll(() async {
      coord = await MergeCoordinator.spawn();
    });

    tearDownAll(() async {
      await coord.dispose();
    });

    test('round-trips an empty overlay (no-op fold)', () async {
      final s = _baseline();
      final merged = await coord.merge(s.csr, s.overlay);
      expect(merged.nodeCount, 5);
      expect(merged.edgeCount, 4);
    });

    test('folds AddEdge through the worker', () async {
      final s = _baseline();
      s.applyAddEdge(
        s.allocEid(),
        logicalId: 'e-new',
        src: const Vid(0),
        dst: const Vid(4),
        typeId: 0,
        props: const {},
      );
      final merged = await coord.merge(s.csr, s.overlay);
      expect(merged.edgeCount, 5);
      expect(merged.outDegree(0), 2);
      expect(merged.inDegree(4), 2);
    });

    test('folds AddNode + AddEdge through the worker', () async {
      final s = _baseline();
      final v = s.allocVid();
      s.applyAddNode(v, logicalId: 'v', labelIds: [0], props: const {});
      s.applyAddEdge(
        s.allocEid(),
        logicalId: 'e',
        src: const Vid(0),
        dst: v,
        typeId: 0,
        props: const {},
      );
      final merged = await coord.merge(s.csr, s.overlay);
      expect(merged.nodeCount, 6);
      expect(merged.edgeCount, 5);
    });

    test('folds DelEdge + DelNode (cascade) through the worker', () async {
      final s = _baseline();
      s.applyDelNode(const Vid(2)); // hides v2 + its incident edges
      final merged = await coord.merge(s.csr, s.overlay);
      // Edges 1 (v1->v2) and 2 (v2->v3) drop; survivors: 0 (v0->v1), 3 (v3->v4).
      expect(merged.edgeCount, 2);
    });

    test('main-isolate stall (copy + install) stays small', () async {
      // 1k base edges → wide enough to surface the copy cost.
      final n = 1024;
      final srcs = Uint32List(n);
      final dsts = Uint32List(n);
      final types = Uint32List(n);
      for (var i = 0; i < n; i++) {
        srcs[i] = i;
        dsts[i] = (i + 1) % n;
      }
      final s = MutableGraphState.fromFixture(
        nodeCount: n,
        srcs: srcs,
        dsts: dsts,
        edgeTypes: types,
        labelOf: Uint32List(n),
        labelNames: const ['Node'],
        edgeTypeNames: const ['link'],
        vidSpace: n + 16,
        eidSpace: n + 16,
      );
      // Add some overlay activity.
      for (var i = 0; i < 64; i++) {
        s.applyAddEdge(
          s.allocEid(),
          logicalId: 'e$i',
          src: Vid(i),
          dst: Vid((i + 100) % n),
          typeId: 0,
          props: const {},
        );
      }
      final sw = Stopwatch()..start();
      final merged = await coord.merge(s.csr, s.overlay);
      sw.stop();
      // End-to-end (copy + worker compute + install ack) — looser
      // bound. The pure main-isolate stall is just the copy; not
      // separately measurable from this test without instrumentation.
      expect(sw.elapsedMicroseconds, lessThan(50000)); // 50ms hard cap
      expect(merged.edgeCount, n + 64);
    });

    test('GraphDb._commit uses the worker when coordinator is wired',
        () async {
      final s = _baseline()..mergeThreshold = 1;
      s.mergeCoordinator = coord;
      final db = GraphDb.fromState(s);
      await db.runTransaction(
        (txn) {
          final v = txn.addNode(labelIds: [0]);
          txn.addEdge(src: const Vid(0), dst: v, typeId: 0);
        },
        durability: Durability.none,
      );
      // Merge fired through the worker; overlay drained.
      expect(s.overlay.isEmpty, isTrue);
      expect(coord.lastMergeWorkerUs, greaterThan(0));
    });
  });
}
