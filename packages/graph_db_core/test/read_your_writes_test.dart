import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// Read-your-writes regression suite — `6_IMPROVED_API_PLAN.md` Step 1.
///
/// A committed mutation must be visible to the engine's own reads
/// immediately, with no explicit `db.state.mergeNow()`. Merge is a
/// background compaction detail, never a correctness requirement.
///
/// This file covers the `labelScan` path. Traversal (`forEachOutNeighbor`
/// / `forEachInNeighbor`) and the scalar reads (`nodeCount` / `edgeCount`
/// / degrees) land in later steps of the plan.

/// A fresh, empty, in-memory engine. `graph_db_core` tests can't pull in
/// `graph_db_wal` (circular), so we build via `GraphDb.fromState` with no
/// sink — `runTransaction` applies directly without a WAL.
GraphDb _emptyDb() {
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const ['Thing'],
    edgeTypeNames: const ['rel'],
    vidSpace: 16,
    eidSpace: 16,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('read-your-writes — labelScan', () {
    test('a committed node is visible to labelScan before any merge',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      late Vid vid;
      await db.runTransaction((txn) {
        vid = txn.addNode(labelIds: [label]);
      });
      // No mergeNow() — the write must already be visible.
      expect(db.labelScan(label), contains(vid.value),
          reason: 'committed write must be visible without an explicit merge');
    });

    test('a committed multi-label node is visible under each of its labels',
        () async {
      final db = _emptyDb();
      final a = db.internLabel('A');
      final b = db.internLabel('B');
      late Vid vid;
      await db.runTransaction((txn) {
        vid = txn.addNode(labelIds: [a, b]);
      });
      expect(db.labelScan(a), contains(vid.value));
      expect(db.labelScan(b), contains(vid.value));
    });

    test('a committed-then-deleted node is excluded before any merge',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      late Vid vid;
      await db.runTransaction((txn) => vid = txn.addNode(labelIds: [label]));
      await db.runTransaction((txn) => txn.delNode(vid));
      expect(db.labelScan(label), isNot(contains(vid.value)));
    });

    test('labelScan stays ascending and matches the post-merge result',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final vids = <int>[];
      await db.runTransaction((txn) {
        for (var i = 0; i < 5; i++) {
          vids.add(txn.addNode(labelIds: [label]).value);
        }
      });
      final pre = db.labelScan(label).toList();
      expect(pre, containsAll(vids));
      expect(pre, orderedEquals(<int>[...pre]..sort()),
          reason: 'labelScan contract: ascending order');

      db.state.mergeNow();
      final post = db.labelScan(label).toList();
      expect(post, orderedEquals(pre),
          reason: 'overlay-aware result must equal the post-merge CSR result');
    });

    test('clean (empty) overlay returns the zero-copy CSR index view',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      await db.runTransaction((txn) => txn.addNode(labelIds: [label]));
      db.state.mergeNow(); // overlay now empty → fast path
      final view = db.labelScan(label);
      expect(identical(view, db.state.csr.labelIndex[label]), isTrue,
          reason: 'empty-overlay fast path must return the CSR view, no copy');
    });
  });

  group('read-your-writes — traversal', () {
    test('an edge committed via runTransaction is visible to forEach'
        'Out/InNeighbor before any merge', () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final rel = db.internEdgeType('rel');
      late Vid a, b;
      await db.runTransaction((txn) {
        a = txn.addNode(labelIds: [label]);
        b = txn.addNode(labelIds: [label]);
        txn.addEdge(src: a, dst: b, typeId: rel);
      });
      final outs = <int>[];
      db.forEachOutNeighbor(a, (dst, eid, t) => outs.add(dst.value));
      expect(outs, contains(b.value));

      final ins = <int>[];
      db.forEachInNeighbor(b, (src, eid, t) => ins.add(src.value));
      expect(ins, contains(a.value));
    });

    test('a removed base-CSR edge is not visited before any merge', () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final rel = db.internEdgeType('rel');
      late Vid a, b;
      late Eid e;
      await db.runTransaction((txn) {
        a = txn.addNode(labelIds: [label]);
        b = txn.addNode(labelIds: [label]);
        e = txn.addEdge(src: a, dst: b, typeId: rel);
      });
      db.state.mergeNow(); // bake the edge into the CSR base
      await db.runTransaction((txn) => txn.delEdge(e));
      final outs = <int>[];
      db.forEachOutNeighbor(a, (dst, eid, t) => outs.add(dst.value));
      expect(outs, isNot(contains(b.value)),
          reason: 'overlay tombstone must hide a base-CSR edge');
    });

    test('an edge to a deleted endpoint is not visited before any merge',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final rel = db.internEdgeType('rel');
      late Vid a, b;
      await db.runTransaction((txn) {
        a = txn.addNode(labelIds: [label]);
        b = txn.addNode(labelIds: [label]);
        txn.addEdge(src: a, dst: b, typeId: rel);
      });
      db.state.mergeNow();
      await db.runTransaction((txn) => txn.delNode(b));
      final outs = <int>[];
      db.forEachOutNeighbor(a, (dst, eid, t) => outs.add(dst.value));
      expect(outs, isNot(contains(b.value)));
    });
  });

  group('read-your-writes — counts and degrees', () {
    test('nodeCount / edgeCount reflect committed adds before any merge and '
        'match the post-merge totals', () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final rel = db.internEdgeType('rel');
      await db.runTransaction((txn) {
        final a = txn.addNode(labelIds: [label]);
        final b = txn.addNode(labelIds: [label]);
        final c = txn.addNode(labelIds: [label]);
        txn.addEdge(src: a, dst: b, typeId: rel);
        txn.addEdge(src: b, dst: c, typeId: rel);
      });
      expect(db.nodeCount, 3);
      expect(db.edgeCount, 2);
      final preNodes = db.nodeCount;
      final preEdges = db.edgeCount;
      db.state.mergeNow();
      expect(db.nodeCount, preNodes, reason: 'nodeCount parity across merge');
      expect(db.edgeCount, preEdges, reason: 'edgeCount parity across merge');
    });

    test('edgeCount drops when a base edge is removed before any merge',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final rel = db.internEdgeType('rel');
      late Eid e;
      await db.runTransaction((txn) {
        final a = txn.addNode(labelIds: [label]);
        final b = txn.addNode(labelIds: [label]);
        e = txn.addEdge(src: a, dst: b, typeId: rel);
      });
      db.state.mergeNow();
      expect(db.edgeCount, 1);
      await db.runTransaction((txn) => txn.delEdge(e));
      expect(db.edgeCount, 0,
          reason: 'an overlay tombstone must reduce edgeCount (RYW)');
    });

    test('outDegree / inDegree reflect overlay edges before any merge',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final rel = db.internEdgeType('rel');
      late Vid a, b;
      await db.runTransaction((txn) {
        a = txn.addNode(labelIds: [label]);
        b = txn.addNode(labelIds: [label]);
        txn.addEdge(src: a, dst: b, typeId: rel);
      });
      expect(db.outDegree(a), 1);
      expect(db.inDegree(b), 1);
    });
  });

  group('read-your-writes — properties and id stability', () {
    test('a node property written in a txn is readable before any merge',
        () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final nameKey = db.internPropKey('name');
      final ageKey = db.internPropKey('age');
      late Vid vid;
      await db.runTransaction((txn) {
        vid = txn.addNode(labelIds: [label], props: {
          nameKey: const PropString('Kai'),
          ageKey: const PropInt(7),
        });
      });
      expect(db.getNodeStringProp(vid, nameKey), 'Kai');
      expect(db.getNodeIntProp(vid, ageKey), 7);
    });

    test('vids and property reads survive a mergeNow()', () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      final nameKey = db.internPropKey('name');
      late Vid a;
      await db.runTransaction((txn) {
        a = txn.addNode(
            labelIds: [label], props: {nameKey: const PropString('A')});
        txn.addNode(
            labelIds: [label], props: {nameKey: const PropString('B')});
      });
      db.state.mergeNow();
      // The vid captured before the merge still resolves the same data
      // and is still found by labelScan.
      expect(db.getNodeStringProp(a, nameKey), 'A');
      expect(db.labelScan(label), contains(a.value));
    });
  });

  group('hasPendingWrites', () {
    test('tracks the overlay dirty state across commit and merge', () async {
      final db = _emptyDb();
      final label = db.internLabel('Thing');
      expect(db.hasPendingWrites, isFalse);
      await db.runTransaction((txn) => txn.addNode(labelIds: [label]));
      expect(db.hasPendingWrites, isTrue);
      db.state.mergeNow();
      expect(db.hasPendingWrites, isFalse);
    });
  });
}
