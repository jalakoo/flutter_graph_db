import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_core/src/merge/merge_fold.dart';
import 'package:test/test.dart';

/// Builds a 3-node, 2-edge baseline (same shape as mutation_test):
///   v0 --e0(link)--> v1 --e1(link)--> v2     (all 'Node' label)
MutableGraphState _baseline() => MutableGraphState.fromFixture(
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

void main() {
  group('foldOverlayIntoCsr — pure fold', () {
    test('empty overlay returns a CSR equivalent to the base', () {
      final s = _baseline();
      final folded = foldOverlayIntoCsr(base: s.csr, overlay: s.overlay);
      expect(folded.nodeCount, 3);
      expect(folded.edgeCount, 2);
      expect(folded.labelOf, [0, 0, 0]);
    });

    test('AddNode + AddEdge land in the folded CSR', () {
      final s = _baseline();
      final v = s.allocVid();
      s.applyAddNode(v, logicalId: 'n', labelIds: [0], props: const {});
      final e = s.allocEid();
      s.applyAddEdge(
        e,
        logicalId: 'e',
        src: const Vid(0),
        dst: v,
        typeId: 0,
        props: const {},
      );
      final folded = foldOverlayIntoCsr(base: s.csr, overlay: s.overlay);
      expect(folded.nodeCount, 4);
      expect(folded.edgeCount, 3);
      // v0 now has 2 out-edges: e0 to v1, e2 to v
      expect(folded.outDegree(0), 2);
      // v has 1 in-edge from v0.
      expect(folded.inDegree(v.value), 1);
    });

    test('DelEdge drops the edge from the folded CSR', () {
      final s = _baseline();
      s.applyDelEdge(const Eid(0));
      final folded = foldOverlayIntoCsr(base: s.csr, overlay: s.overlay);
      expect(folded.edgeCount, 1);
      // v0 has no more out-edges; v1 has no more in-edges from v0.
      expect(folded.outDegree(0), 0);
      expect(folded.inDegree(1), 0);
    });

    test('DelNode cascades: incident edges drop from the folded CSR', () {
      final s = _baseline();
      s.applyDelNode(const Vid(1));
      final folded = foldOverlayIntoCsr(base: s.csr, overlay: s.overlay);
      expect(folded.edgeCount, 0); // both base edges incident to v1
    });

    test('SetNodeLabels label override survives the fold', () {
      final s = _baseline();
      final newL = s.strings.internLabel('Vip');
      s.applySetNodeLabels(
        const Vid(0),
        added: [newL],
        removed: const [0],
      );
      final folded = foldOverlayIntoCsr(base: s.csr, overlay: s.overlay);
      expect(folded.labelOf[0], newL);
    });

    test('reverse CSR correct after fold (Spike B carry-forward)', () {
      // Add several edges into a fresh dst node; verify reverse-CSR
      // sees all of them after fold.
      final s = _baseline();
      final hub = s.allocVid();
      s.applyAddNode(hub, logicalId: 'hub', labelIds: [0], props: const {});
      for (var i = 0; i < 5; i++) {
        s.applyAddEdge(
          s.allocEid(),
          logicalId: 'e$i',
          src: const Vid(0),
          dst: hub,
          typeId: 0,
          props: const {},
        );
      }
      final folded = foldOverlayIntoCsr(base: s.csr, overlay: s.overlay);
      expect(folded.inDegree(hub.value), 5);
    });
  });

  group('merge trigger + install', () {
    test('maybeMergeOverlay no-op when below threshold', () {
      final s = _baseline()..mergeThreshold = 1000;
      // Single mutation — well below.
      s.applyAddNode(s.allocVid(),
          logicalId: 'x', labelIds: [0], props: const {});
      expect(s.maybeMergeOverlay(), isFalse);
      // Overlay still has the addition.
      expect(s.overlay.addedNodes.length, 1);
    });

    test('maybeMergeOverlay folds + clears overlay when threshold met', () {
      final s = _baseline()..mergeThreshold = 2;
      final a = s.allocVid();
      final b = s.allocVid();
      s.applyAddNode(a, logicalId: 'a', labelIds: [0], props: const {});
      s.applyAddNode(b, logicalId: 'b', labelIds: [0], props: const {});
      s.applyAddEdge(
        s.allocEid(),
        logicalId: 'e1',
        src: a,
        dst: b,
        typeId: 0,
        props: const {},
      );
      s.applyAddEdge(
        s.allocEid(),
        logicalId: 'e2',
        src: b,
        dst: a,
        typeId: 0,
        props: const {},
      );
      // 2 added edges = at threshold → merge fires.
      final csrBefore = s.csr;
      final fired = s.maybeMergeOverlay();
      expect(fired, isTrue);
      expect(s.csr, isNot(same(csrBefore)));
      // New CSR has 4 edges (2 base + 2 new).
      expect(s.csr.edgeCount, 4);
      // Overlay drained.
      expect(s.overlay.isEmpty, isTrue);
    });

    test('reads cross the merge boundary cleanly', () {
      final s = _baseline()..mergeThreshold = 1;
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
      // Pre-merge: read sees the new edge through the overlay path.
      var preCount = 0;
      s.forEachOutEdge(const Vid(0), (_, __, ___) => preCount++);
      expect(preCount, 2);
      // Force merge.
      s.maybeMergeOverlay();
      // Post-merge: same read goes through the CSR base — same answer.
      var postCount = 0;
      s.forEachOutEdge(const Vid(0), (_, __, ___) => postCount++);
      expect(postCount, 2);
    });

    test('baseCsrEidToSrc / baseCsrEidToDst rebuilt after install', () {
      final s = _baseline()..mergeThreshold = 1;
      final v = s.allocVid();
      s.applyAddNode(v, logicalId: 'v', labelIds: [0], props: const {});
      final newEid = s.allocEid();
      s.applyAddEdge(
        newEid,
        logicalId: 'e',
        src: const Vid(0),
        dst: v,
        typeId: 0,
        props: const {},
      );
      s.maybeMergeOverlay();
      // The new edge's eid resolves through the rebuilt eid->src map.
      // (Test the resolver by deleting the edge — applyDelEdge uses
      // baseCsrEidToSrc/Dst to find the endpoints.)
      expect(() => s.applyDelEdge(newEid), returnsNormally);
    });
  });

  group('GraphDb._commit triggers merge', () {
    test('commit past threshold installs a new CSR', () async {
      final state = _baseline()..mergeThreshold = 1;
      final db = GraphDb.fromState(state);
      final lbl = db.internLabel('Node');
      final csrBefore = state.csr;
      await db.runTransaction((txn) {
        txn.addNode(labelIds: [lbl]);
      });
      // After commit, threshold (1 added edge or node? actual formula
      // counts added edges + deleted edges) — but we set
      // mergeThreshold=1 and added 0 edges, so no merge yet.
      expect(state.csr, same(csrBefore));
      await db.runTransaction((txn) {
        final v = txn.addNode(labelIds: [lbl]);
        txn.addEdge(src: const Vid(0), dst: v, typeId: 0);
      });
      // Now overlayMutationCount >= 1 → merge fires.
      expect(state.csr, isNot(same(csrBefore)));
      expect(state.overlay.isEmpty, isTrue);
    });
  });

  // ----- Multi-label rollout PR 2: ragged-CSR fold -----
  group('multi-label fold (PR 2)', () {
    test('overlay-added node with 3 labels lands in every label bucket',
        () async {
      final state = _baseline()..mergeThreshold = 1;
      final db = GraphDb.fromState(state);
      final a = db.internLabel('A');
      final b = db.internLabel('B');
      final c = db.internLabel('C');
      late Vid v;
      await db.runTransaction((txn) {
        v = txn.addNode(labelIds: [a, b, c]);
        txn.addEdge(src: const Vid(0), dst: v, typeId: 0);
      });
      expect(state.overlay.isEmpty, isTrue);
      expect(state.csr.labelIndex[a], contains(v.value));
      expect(state.csr.labelIndex[b], contains(v.value));
      expect(state.csr.labelIndex[c], contains(v.value));
      expect(state.csr.hasLabel(v.value, a), isTrue);
      expect(state.csr.hasLabel(v.value, b), isTrue);
      expect(state.csr.hasLabel(v.value, c), isTrue);
      // Ragged labels round-trip — sorted ascending.
      expect(
        state.csr.labelsOf(v.value).toList(),
        orderedEquals(<int>[a, b, c]..sort()),
      );
    });

    test('label-override (existing CSR vid) lands in fresh buckets',
        () async {
      final state = _baseline()..mergeThreshold = 1;
      final db = GraphDb.fromState(state);
      final extra = db.internLabel('Vip');
      // vid 0 starts with label 0 in the baseline fixture. Add an
      // extra label and force a merge.
      await db.runTransaction((txn) {
        txn.setNodeLabels(const Vid(0), added: [extra], removed: const []);
        // Force a merge via an unrelated edge addition.
        final v = txn.addNode(labelIds: [0]);
        txn.addEdge(src: const Vid(0), dst: v, typeId: 0);
      });
      expect(state.overlay.isEmpty, isTrue);
      // vid 0 should appear in both its original label-0 bucket AND
      // the new 'extra' bucket.
      expect(state.csr.labelIndex[0], contains(0));
      expect(state.csr.labelIndex[extra], contains(0));
      expect(state.csr.hasLabel(0, 0), isTrue);
      expect(state.csr.hasLabel(0, extra), isTrue);
    });
  });
}
