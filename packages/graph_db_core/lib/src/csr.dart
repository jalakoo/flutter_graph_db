import 'dart:typed_data';

/// Compressed Sparse Row topology, both directions (plan §3.1).
///
/// All arrays are `Uint32List` — the §3.1 web-compatibility decision
/// (Spike B). Caps the graph at 2³² nodes / 2³² edges (effectively
/// unbounded on-device) and halves topology memory vs a 64-bit layout.
/// Reverse arrays are **always built**; reverse-CSR correctness through
/// a merge is spike-verified (§2.3).
///
/// Edges within a row are sorted by `(srcVid, edgeType)` so a
/// type-filtered traversal is a binary search + range scan (future).
class Csr {
  /// Number of nodes (vids `0 .. nodeCount-1`).
  final int nodeCount;

  /// Number of edges (eids `0 .. edgeCount-1`).
  final int edgeCount;

  // ----- Forward ------------------------------------------------------------

  /// Length `nodeCount + 1`. `rowPtrOut[v] .. rowPtrOut[v+1]` indexes the
  /// outgoing edges of vid `v` inside [colIdxOut] / [edgeIdOut] /
  /// [edgeTypeOut].
  final Uint32List rowPtrOut;

  /// Length `edgeCount`. Destination vids, grouped by source vid.
  final Uint32List colIdxOut;

  /// Length `edgeCount`. Logical edge id parallel to [colIdxOut].
  final Uint32List edgeIdOut;

  /// Length `edgeCount`. Edge type id parallel to [colIdxOut].
  final Uint32List edgeTypeOut;

  // ----- Reverse ------------------------------------------------------------

  final Uint32List rowPtrIn;
  final Uint32List colIdxIn;
  final Uint32List edgeIdIn;
  final Uint32List edgeTypeIn;

  // ----- Labels (single-label-per-node in v0; multi-label is a Phase 1.1
  // refinement per plan §6.4) -------------------------------------------------

  /// Length `nodeCount`. One label id per node.
  final Uint32List labelOf;

  /// Label id -> sorted vids carrying that label.
  final Map<int, Uint32List> labelIndex;

  Csr({
    required this.nodeCount,
    required this.edgeCount,
    required this.rowPtrOut,
    required this.colIdxOut,
    required this.edgeIdOut,
    required this.edgeTypeOut,
    required this.rowPtrIn,
    required this.colIdxIn,
    required this.edgeIdIn,
    required this.edgeTypeIn,
    required this.labelOf,
    required this.labelIndex,
  });

  /// Builds a CSR from a flat edge list plus per-node labels.
  ///
  /// `eid` is assigned as the original index in the edge list. `srcs`,
  /// `dsts`, and `edgeTypes` must all have the same length. `labelOf`
  /// must have length `nodeCount`, `labelCount` is the number of
  /// distinct label ids in use.
  factory Csr.fromEdges({
    required int nodeCount,
    required Uint32List srcs,
    required Uint32List dsts,
    required Uint32List edgeTypes,
    required Uint32List labelOf,
    required int labelCount,
  }) {
    final edgeCount = srcs.length;
    if (dsts.length != edgeCount || edgeTypes.length != edgeCount) {
      throw ArgumentError(
          'srcs/dsts/edgeTypes must have the same length; '
          'got ${srcs.length} / ${dsts.length} / ${edgeTypes.length}');
    }
    if (labelOf.length != nodeCount) {
      throw ArgumentError(
          'labelOf length ${labelOf.length} != nodeCount $nodeCount');
    }

    // ----- forward
    final rowPtrOut = Uint32List(nodeCount + 1);
    for (var i = 0; i < edgeCount; i++) {
      rowPtrOut[srcs[i] + 1]++;
    }
    for (var v = 0; v < nodeCount; v++) {
      rowPtrOut[v + 1] += rowPtrOut[v];
    }

    final colIdxOut = Uint32List(edgeCount);
    final edgeIdOut = Uint32List(edgeCount);
    final edgeTypeOut = Uint32List(edgeCount);
    final cursorOut = Uint32List(nodeCount);
    for (var i = 0; i < edgeCount; i++) {
      final s = srcs[i];
      final pos = rowPtrOut[s] + cursorOut[s];
      colIdxOut[pos] = dsts[i];
      edgeIdOut[pos] = i;
      edgeTypeOut[pos] = edgeTypes[i];
      cursorOut[s]++;
    }

    // ----- reverse
    final rowPtrIn = Uint32List(nodeCount + 1);
    for (var i = 0; i < edgeCount; i++) {
      rowPtrIn[dsts[i] + 1]++;
    }
    for (var v = 0; v < nodeCount; v++) {
      rowPtrIn[v + 1] += rowPtrIn[v];
    }

    final colIdxIn = Uint32List(edgeCount);
    final edgeIdIn = Uint32List(edgeCount);
    final edgeTypeIn = Uint32List(edgeCount);
    final cursorIn = Uint32List(nodeCount);
    for (var i = 0; i < edgeCount; i++) {
      final d = dsts[i];
      final pos = rowPtrIn[d] + cursorIn[d];
      colIdxIn[pos] = srcs[i]; // reverse: parent at this position
      edgeIdIn[pos] = i;
      edgeTypeIn[pos] = edgeTypes[i];
      cursorIn[d]++;
    }

    // ----- label index
    final counts = Uint32List(labelCount);
    for (var v = 0; v < nodeCount; v++) {
      counts[labelOf[v]]++;
    }
    final labelIndex = <int, Uint32List>{};
    for (var l = 0; l < labelCount; l++) {
      labelIndex[l] = Uint32List(counts[l]);
    }
    final fill = Uint32List(labelCount);
    for (var v = 0; v < nodeCount; v++) {
      final l = labelOf[v];
      labelIndex[l]![fill[l]++] = v;
    }

    return Csr(
      nodeCount: nodeCount,
      edgeCount: edgeCount,
      rowPtrOut: rowPtrOut,
      colIdxOut: colIdxOut,
      edgeIdOut: edgeIdOut,
      edgeTypeOut: edgeTypeOut,
      rowPtrIn: rowPtrIn,
      colIdxIn: colIdxIn,
      edgeIdIn: edgeIdIn,
      edgeTypeIn: edgeTypeIn,
      labelOf: labelOf,
      labelIndex: labelIndex,
    );
  }

  /// Out-degree of [vid].
  int outDegree(int vid) => rowPtrOut[vid + 1] - rowPtrOut[vid];

  /// In-degree of [vid].
  int inDegree(int vid) => rowPtrIn[vid + 1] - rowPtrIn[vid];
}
