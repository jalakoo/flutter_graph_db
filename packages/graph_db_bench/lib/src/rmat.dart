import 'dart:math';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

/// Raw R-MAT edge / label arrays — the shape `MutableGraphState.fromFixture`
/// expects.
class RmatEdges {
  final int nodeCount;
  final int edgeCount;
  final Uint32List srcs;
  final Uint32List dsts;
  final Uint32List edgeTypes;
  final Uint32List labelOf;
  final int labelCount;
  final List<String> labelNames;
  final List<String> edgeTypeNames;

  const RmatEdges({
    required this.nodeCount,
    required this.edgeCount,
    required this.srcs,
    required this.dsts,
    required this.edgeTypes,
    required this.labelOf,
    required this.labelCount,
    required this.labelNames,
    required this.edgeTypeNames,
  });
}

/// Generates an R-MAT graph. [nodeCount] must be a power of two. Defaults
/// match the SPIKE_A fixture: 0.57 / 0.19 / 0.19 / 0.05 quadrant
/// probabilities — produces a skewed degree distribution that's a
/// realistic stress for the read primitives.
RmatEdges rmat({
  required int nodeCount,
  required int edgeCount,
  required int labelCount,
  int seed = 0x5eed,
  double a = 0.57,
  double b = 0.19,
  double c = 0.19,
  List<String>? labelNames,
  List<String>? edgeTypeNames,
}) {
  if ((nodeCount & (nodeCount - 1)) != 0) {
    throw ArgumentError.value(
        nodeCount, 'nodeCount', 'must be a power of two');
  }
  final rng = Random(seed);
  final srcs = Uint32List(edgeCount);
  final dsts = Uint32List(edgeCount);
  final bits = _log2(nodeCount);
  final ab = a + b;
  final abc = a + b + c;

  for (var e = 0; e < edgeCount; e++) {
    var x = 0;
    var y = 0;
    for (var bit = 0; bit < bits; bit++) {
      final r = rng.nextDouble();
      if (r < a) {
        // quadrant (0, 0)
      } else if (r < ab) {
        y |= 1 << bit;
      } else if (r < abc) {
        x |= 1 << bit;
      } else {
        x |= 1 << bit;
        y |= 1 << bit;
      }
    }
    srcs[e] = x;
    dsts[e] = y;
  }

  final labelOf = Uint32List(nodeCount);
  for (var v = 0; v < nodeCount; v++) {
    labelOf[v] = rng.nextInt(labelCount);
  }

  // Single edge type for the synthetic graph; the bench doesn't measure
  // type-filtered traversal yet (plan §3.1 sorts edges by type but
  // type-filtered range scan is a Phase 1.1 feature).
  final edgeTypes = Uint32List(edgeCount);

  return RmatEdges(
    nodeCount: nodeCount,
    edgeCount: edgeCount,
    srcs: srcs,
    dsts: dsts,
    edgeTypes: edgeTypes,
    labelOf: labelOf,
    labelCount: labelCount,
    labelNames: labelNames ??
        List.generate(labelCount, (i) => 'label_$i', growable: false),
    edgeTypeNames: edgeTypeNames ?? const ['edge'],
  );
}

/// Convenience: wraps [rmat] output in a [MutableGraphState] sized for
/// in-place mutation headroom (matches the example app's pattern).
MutableGraphState buildFixture(RmatEdges r) {
  return MutableGraphState.fromFixture(
    nodeCount: r.nodeCount,
    srcs: r.srcs,
    dsts: r.dsts,
    edgeTypes: r.edgeTypes,
    labelOf: r.labelOf,
    labelNames: r.labelNames,
    edgeTypeNames: r.edgeTypeNames,
    vidSpace: r.nodeCount,
    eidSpace: r.edgeCount,
  );
}

int _log2(int n) {
  var r = 0;
  var v = n;
  while (v > 1) {
    v >>= 1;
    r++;
  }
  return r;
}
