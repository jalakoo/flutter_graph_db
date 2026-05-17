import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// Builds a 3-node, 2-edge baseline:
///   v0 --e0(link)--> v1 --e1(link)--> v2     (all Node label)
MutableGraphState _baseline() {
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
  return state;
}

void main() {
  group('allocators', () {
    test('allocVid issues monotonically increasing fresh ids', () {
      final s = _baseline();
      expect(s.nextVid, 3);
      final a = s.allocVid();
      final b = s.allocVid();
      expect(a.value, 3);
      expect(b.value, 4);
      expect(s.nextVid, 5);
    });

    test('allocEid issues monotonically increasing fresh ids', () {
      final s = _baseline();
      expect(s.nextEid, 2);
      final a = s.allocEid();
      final b = s.allocEid();
      expect(a.value, 2);
      expect(b.value, 3);
    });

    test('allocVid grows nodeProps vidSpace past the initial cap', () {
      final s = _baseline();
      expect(s.nodeProps.vidSpace, 16);
      for (var i = 0; i < 30; i++) {
        s.allocVid();
      }
      expect(s.nodeProps.vidSpace, greaterThanOrEqualTo(33));
    });
  });

  group('AddNode', () {
    test('makes a vid visible with the recorded label', () {
      final s = _baseline();
      final v = s.allocVid();
      s.applyAddNode(
        v,
        logicalId: 'n-new',
        labelIds: [0],
        props: const {},
      );
      expect(s.isNodeVisible(v), isTrue);
      expect(s.effectiveLabelOf(v), 0);
      expect(s.overlay.addedNodes.containsKey(v.value), isTrue);
    });

    test('vid-reuse on an already-tombstoned vid is rejected', () {
      final s = _baseline();
      s.applyDelNode(const Vid(0));
      expect(
        () => s.applyAddNode(
          const Vid(0),
          logicalId: 'reuse',
          labelIds: [0],
          props: const {},
        ),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('AddNode with explicit vid past nextVid fast-forwards the counter',
        () {
      final s = _baseline();
      s.applyAddNode(
        const Vid(10),
        logicalId: 'n-10',
        labelIds: [0],
        props: const {},
      );
      expect(s.nextVid, 11);
      expect(s.allocVid().value, 11);
    });

    test('AddNode writes props through the typed columns', () {
      final s = _baseline();
      final name = s.strings.internPropKey('name');
      final age = s.strings.internPropKey('age');
      final v = s.allocVid();
      s.applyAddNode(
        v,
        logicalId: 'n-new',
        labelIds: [0],
        props: {
          name: const PropString('Ada'),
          age: const PropInt(36),
        },
      );
      expect(s.nodeProps.getString(v.value, name), 'Ada');
      expect(s.nodeProps.getInt(v.value, age), 36);
    });

    test('AddNode with empty labels rejects (v1 single-label, ≥ 1)', () {
      final s = _baseline();
      expect(
        () => s.applyAddNode(
          s.allocVid(),
          logicalId: 'x',
          labelIds: const [],
          props: const {},
        ),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('AddNode with multi-label rejects (v1 single-label)', () {
      final s = _baseline();
      expect(
        () => s.applyAddNode(
          s.allocVid(),
          logicalId: 'x',
          labelIds: const [0, 0],
          props: const {},
        ),
        throwsA(isA<ConstraintViolation>()),
      );
    });
  });

  group('DelNode (cascade)', () {
    test('hides the node from reads', () {
      final s = _baseline();
      s.applyDelNode(const Vid(1));
      expect(s.isNodeVisible(const Vid(1)), isFalse);
    });

    test('cascades to all incident base-CSR edges', () {
      final s = _baseline();
      s.applyDelNode(const Vid(1));
      // v0's outgoing e0 is incident to deleted v1 → hidden
      final v0Out = <int>[];
      s.forEachOutEdge(const Vid(0), (eid, _, __) => v0Out.add(eid.value));
      expect(v0Out, isEmpty);
      // v2's incoming e1 from deleted v1 → hidden
      final v2In = <int>[];
      s.forEachInEdge(const Vid(2), (eid, _, __) => v2In.add(eid.value));
      expect(v2In, isEmpty);
    });

    test('idempotent', () {
      final s = _baseline();
      s.applyDelNode(const Vid(0));
      expect(() => s.applyDelNode(const Vid(0)), returnsNormally);
    });
  });

  group('AddEdge', () {
    test('appears in both forward and reverse iteration of its endpoints',
        () {
      final s = _baseline();
      final eid = s.allocEid();
      s.applyAddEdge(
        eid,
        logicalId: 'e-new',
        src: const Vid(0),
        dst: const Vid(2),
        typeId: 0,
        props: const {},
      );
      final out = <int>[];
      s.forEachOutEdge(const Vid(0), (e, _, __) => out.add(e.value));
      expect(out, contains(eid.value));
      final inV = <int>[];
      s.forEachInEdge(const Vid(2), (e, _, __) => inV.add(e.value));
      expect(inV, contains(eid.value));
    });

    test('rejects edges with a non-existent endpoint', () {
      final s = _baseline();
      final eid = s.allocEid();
      expect(
        () => s.applyAddEdge(
          eid,
          logicalId: 'bogus',
          src: const Vid(0),
          dst: const Vid(99),
          typeId: 0,
          props: const {},
        ),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('AddEdge between two newly-added nodes', () {
      final s = _baseline();
      final a = s.allocVid();
      final b = s.allocVid();
      s.applyAddNode(a,
          logicalId: 'a', labelIds: [0], props: const {});
      s.applyAddNode(b,
          logicalId: 'b', labelIds: [0], props: const {});
      final e = s.allocEid();
      s.applyAddEdge(
        e,
        logicalId: 'e',
        src: a,
        dst: b,
        typeId: 0,
        props: const {},
      );
      final out = <int>[];
      s.forEachOutEdge(a, (_, dst, __) => out.add(dst.value));
      expect(out, [b.value]);
    });
  });

  group('DelEdge', () {
    test('hides a base-CSR edge from both directions', () {
      final s = _baseline();
      s.applyDelEdge(const Eid(0));
      final v0Out = <int>[];
      s.forEachOutEdge(const Vid(0), (e, _, __) => v0Out.add(e.value));
      expect(v0Out, isEmpty);
      final v1In = <int>[];
      s.forEachInEdge(const Vid(1), (e, _, __) => v1In.add(e.value));
      expect(v1In, isEmpty);
    });

    test('hides an overlay-added edge cleanly', () {
      final s = _baseline();
      final e = s.allocEid();
      s.applyAddEdge(
        e,
        logicalId: 'tmp',
        src: const Vid(0),
        dst: const Vid(2),
        typeId: 0,
        props: const {},
      );
      s.applyDelEdge(e);
      final out = <int>[];
      s.forEachOutEdge(const Vid(0), (eid, _, __) => out.add(eid.value));
      expect(out, [0]); // only the original base edge survives
    });

    test('idempotent', () {
      final s = _baseline();
      s.applyDelEdge(const Eid(0));
      expect(() => s.applyDelEdge(const Eid(0)), returnsNormally);
    });

    test('unknown eid raises NotFoundException', () {
      final s = _baseline();
      expect(
        () => s.applyDelEdge(const Eid(999)),
        throwsA(isA<NotFoundException>()),
      );
    });
  });

  group('Property mutations', () {
    test('SetNodeProp / DelNodeProp', () {
      final s = _baseline();
      final k = s.strings.internPropKey('age');
      s.applySetNodeProp(const Vid(0), k, const PropInt(30));
      expect(s.nodeProps.getInt(0, k), 30);
      s.applyDelNodeProp(const Vid(0), k);
      expect(s.nodeProps.has(0, k), isFalse);
    });

    test('SetEdgeProp / DelEdgeProp', () {
      final s = _baseline();
      final k = s.strings.internPropKey('weight');
      s.applySetEdgeProp(const Eid(0), k, const PropDouble(1.5));
      expect(s.edgeProps.getDouble(0, k), 1.5);
      s.applyDelEdgeProp(const Eid(0), k);
      expect(s.edgeProps.has(0, k), isFalse);
    });

    test('PropList / PropMap props are rejected at the column boundary',
        () {
      final s = _baseline();
      final k = s.strings.internPropKey('tags');
      expect(
        () => s.applySetNodeProp(const Vid(0), k, const PropList([])),
        throwsA(isA<ConstraintViolation>()),
      );
    });
  });

  group('SetNodeLabels', () {
    test('relabels a pre-existing CSR node', () {
      final s = _baseline();
      final newLabel = s.strings.internLabel('Vip');
      s.applySetNodeLabels(
        const Vid(0),
        added: [newLabel],
        removed: const [0],
      );
      expect(s.effectiveLabelOf(const Vid(0)), newLabel);
    });

    test('relabels an overlay-added node in place', () {
      final s = _baseline();
      final v = s.allocVid();
      s.applyAddNode(v, logicalId: 'x', labelIds: [0], props: const {});
      final newLabel = s.strings.internLabel('Vip');
      s.applySetNodeLabels(v, added: [newLabel], removed: const [0]);
      expect(s.effectiveLabelOf(v), newLabel);
    });

    test('multi-label rejected (v1)', () {
      final s = _baseline();
      expect(
        () => s.applySetNodeLabels(
          const Vid(0),
          added: const [0, 1],
          removed: const [],
        ),
        throwsA(isA<ConstraintViolation>()),
      );
    });
  });

  group('overlay-aware reads on the base graph', () {
    test('forEachOutEdge / forEachInEdge mirror CSR before any mutation',
        () {
      final s = _baseline();
      final fwd = <int>[];
      s.forEachOutEdge(const Vid(0), (_, dst, __) => fwd.add(dst.value));
      expect(fwd, [1]);
      final rev = <int>[];
      s.forEachInEdge(const Vid(2), (_, src, __) => rev.add(src.value));
      expect(rev, [1]);
    });

    test('effective degrees reflect overlay', () {
      final s = _baseline();
      expect(s.effectiveOutDegree(const Vid(0)), 1);
      // add another out-edge for vid 0
      s.applyAddEdge(
        s.allocEid(),
        logicalId: 'e',
        src: const Vid(0),
        dst: const Vid(2),
        typeId: 0,
        props: const {},
      );
      expect(s.effectiveOutDegree(const Vid(0)), 2);
      // delete the base edge
      s.applyDelEdge(const Eid(0));
      expect(s.effectiveOutDegree(const Vid(0)), 1);
    });
  });
}
