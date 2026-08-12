import 'dart:typed_data';

/// Compressed Sparse Row topology, both directions.
///
/// All arrays are `Uint32List` — the web-compatibility decision
///. Caps the graph at 2³² nodes / 2³² edges (effectively
/// unbounded on-device) and halves topology memory vs a 64-bit layout.
/// Reverse arrays are **always built**; reverse-CSR correctness through
/// a merge is spike-verified.
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

  // ----- Labels -------------------------------------------------
  //
  // PR 1 of the multi-label rollout (`5_MULTILABEL_PLAN.md`) adds the
  // ragged-CSR fields [labelRowPtr] + [labels] alongside the legacy
  // single-label [labelOf]. While the engine still enforces one label
  // per node (the single-label invariant is lifted in PR 2), the new
  // accessors `hasLabel` / `labelsOf` are available on the read path
  // so callers can migrate ahead of the applicator change. [labelOf]
  // is removed in PR 2.

  /// Length `nodeCount`. One label id per node. **Transitional** —
  /// equivalent to `labels[labelRowPtr[v]]` while the single-label
  /// invariant holds. Removed in PR 2.
  final Uint32List labelOf;

  /// Length `nodeCount + 1`. `labelRowPtr[v] .. labelRowPtr[v+1]`
  /// indexes vid `v`'s labels inside [labels]. Each row is sorted
  /// ascending so `hasLabel` is a binary search.
  final Uint32List labelRowPtr;

  /// Flat label-id stream, length `labelRowPtr.last`. Sorted ascending
  /// within each row.
  final Uint32List labels;

  /// Label id -> sorted vids carrying that label.
  final Map<int, Uint32List> labelIndex;

  // ----- Tombstones ---------------------------------------------------------

  /// Length `nodeCount` when present; a `1` byte marks vid `v` as
  /// deleted. `null` means "no node has ever been deleted in this CSR"
  /// — the common case, kept null so a delete-free graph pays nothing.
  ///
  /// A tombstoned row stays addressable (vids are never reused, so a
  /// previously-issued [Vid] must not silently rebind to a different
  /// node) but is excluded from [labelIndex] and reports `false` from
  /// [isTombstoned]'s inverse — see `MutableGraphState.isNodeVisible`.
  ///
  /// **This must survive a merge.** The overlay's `deletedNodes` set is
  /// cleared when a fold installs a fresh CSR, so the fold folds the
  /// overlay tombstones into this array; without it a deleted node
  /// becomes visible again after the next merge.
  final Uint8List? nodeTombstones;

  // ----- eid -> endpoint maps -----------------------------------------------
  //
  // Built once inside [fromEdges], alongside the forward arrays it
  // already walks. Previously `MutableGraphState` rebuilt these with
  // three extra O(V+E) passes on every `installMergedCsr` — i.e. on the
  // main isolate, immediately after the worker fold returned, which made
  // "install is a pointer swap" untrue. Carrying them on the CSR means
  // the worker computes them and install really is a pointer swap.

  /// `eid -> source vid`, length `maxEid + 1` (eids are sparse — deletions
  /// leave gaps — so this is sized by the largest surviving eid, not by
  /// [edgeCount]). Entries for absent eids are `0`; callers must only
  /// index eids known to be in this CSR.
  final Uint32List eidToSrc;

  /// `eid -> destination vid`. See [eidToSrc].
  final Uint32List eidToDst;

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
    required this.labelRowPtr,
    required this.labels,
    required this.labelIndex,
    required this.eidToSrc,
    required this.eidToDst,
    this.nodeTombstones,
  });

  /// True iff [vid] is tombstoned (deleted). Allocation-free, O(1).
  bool isTombstoned(int vid) {
    final t = nodeTombstones;
    return t != null && vid < t.length && t[vid] != 0;
  }

  /// Number of tombstoned rows. O(nodeCount) — diagnostics only.
  int get tombstoneCount {
    final t = nodeTombstones;
    if (t == null) return 0;
    var n = 0;
    for (var i = 0; i < t.length; i++) {
      if (t[i] != 0) n++;
    }
    return n;
  }

  /// Builds a CSR from a flat edge list plus per-node labels.
  ///
  /// `eid` defaults to the input index — pass [eids] (same length as
  /// [srcs]) to use a different mapping, which is what callers do when
  /// they've already filtered out tombstoned edges but want the
  /// surviving entries to keep their original eids.
  ///
  /// [nodeTombstones] (optional, length `nodeCount`): bytes with `1`
  /// mark a vid as deleted — it is excluded from [labelIndex] but its
  /// row remains addressable so previously-issued [Vid] handles do not
  /// silently rebind to a different node. `null` ⇒ no tombstones.
  ///
  /// `srcs`, `dsts`, and `edgeTypes` must all have the same length.
  /// `labelOf` must have length `nodeCount`. `labelCount` is the number
  /// of distinct label ids in use.
  factory Csr.fromEdges({
    required int nodeCount,
    required Uint32List srcs,
    required Uint32List dsts,
    required Uint32List edgeTypes,
    required Uint32List labelOf,
    required int labelCount,
    Uint32List? eids,
    Uint8List? nodeTombstones,
    // Optional ragged-labels input. When both are present, they take
    // precedence over [labelOf] for per-vid label storage and label
    // index construction. [labelOf] is still required and is used by
    // the (transitional) legacy field on the resulting Csr. Callers
    // like the merge fold pass these to preserve multi-label rows
    // that wouldn't fit in [labelOf]. Multi-label rollout PR 2.
    Uint32List? labelRowPtr,
    Uint32List? labels,
  }) {
    final edgeCount = srcs.length;
    if (dsts.length != edgeCount || edgeTypes.length != edgeCount) {
      throw ArgumentError(
          'srcs/dsts/edgeTypes must have the same length; '
          'got ${srcs.length} / ${dsts.length} / ${edgeTypes.length}');
    }
    if (eids != null && eids.length != edgeCount) {
      throw ArgumentError(
          'eids length ${eids.length} != edge count $edgeCount');
    }
    if (labelOf.length != nodeCount) {
      throw ArgumentError(
          'labelOf length ${labelOf.length} != nodeCount $nodeCount');
    }
    if (nodeTombstones != null && nodeTombstones.length != nodeCount) {
      throw ArgumentError(
          'nodeTombstones length ${nodeTombstones.length} != nodeCount $nodeCount');
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
      edgeIdOut[pos] = eids?[i] ?? i;
      edgeTypeOut[pos] = edgeTypes[i];
      cursorOut[s]++;
    }

    // ----- eid -> endpoint maps. One extra O(E) pass here replaces the
    // three O(V+E) passes `installMergedCsr` used to run on the main
    // isolate after every fold.
    var maxEid = 0;
    for (var i = 0; i < edgeCount; i++) {
      final e = eids?[i] ?? i;
      if (e > maxEid) maxEid = e;
    }
    final eidToSrc = Uint32List(edgeCount == 0 ? 0 : maxEid + 1);
    final eidToDst = Uint32List(edgeCount == 0 ? 0 : maxEid + 1);
    for (var i = 0; i < edgeCount; i++) {
      final e = eids?[i] ?? i;
      eidToSrc[e] = srcs[i];
      eidToDst[e] = dsts[i];
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
      edgeIdIn[pos] = eids?[i] ?? i;
      edgeTypeIn[pos] = edgeTypes[i];
      cursorIn[d]++;
    }

    // ----- ragged labels — either from the optional inputs or
    // synthesised from single-label [labelOf].
    final Uint32List effLabelRowPtr;
    final Uint32List effLabels;
    if (labelRowPtr != null && labels != null) {
      if (labelRowPtr.length != nodeCount + 1) {
        throw ArgumentError(
            'labelRowPtr length ${labelRowPtr.length} != nodeCount+1 '
            '(${nodeCount + 1})');
      }
      if (labels.length != labelRowPtr[nodeCount]) {
        throw ArgumentError(
            'labels length ${labels.length} != labelRowPtr.last '
            '${labelRowPtr[nodeCount]}');
      }
      effLabelRowPtr = labelRowPtr;
      effLabels = labels;
    } else {
      effLabelRowPtr = Uint32List(nodeCount + 1);
      for (var v = 0; v < nodeCount; v++) {
        effLabelRowPtr[v + 1] = v + 1;
      }
      effLabels = Uint32List.fromList(labelOf);
    }

    // ----- label index (tombstoned vids are excluded). Built from
    // the ragged form so multi-label vids land in every bucket.
    final counts = Uint32List(labelCount);
    for (var v = 0; v < nodeCount; v++) {
      if (nodeTombstones != null && nodeTombstones[v] != 0) continue;
      final end = effLabelRowPtr[v + 1];
      for (var i = effLabelRowPtr[v]; i < end; i++) {
        final l = effLabels[i];
        if (l < labelCount) counts[l]++;
      }
    }
    final labelIndex = <int, Uint32List>{};
    for (var l = 0; l < labelCount; l++) {
      labelIndex[l] = Uint32List(counts[l]);
    }
    final fill = Uint32List(labelCount);
    for (var v = 0; v < nodeCount; v++) {
      if (nodeTombstones != null && nodeTombstones[v] != 0) continue;
      final end = effLabelRowPtr[v + 1];
      for (var i = effLabelRowPtr[v]; i < end; i++) {
        final l = effLabels[i];
        if (l < labelCount) labelIndex[l]![fill[l]++] = v;
      }
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
      labelRowPtr: effLabelRowPtr,
      labels: effLabels,
      labelIndex: labelIndex,
      eidToSrc: eidToSrc,
      eidToDst: eidToDst,
      // Retain the tombstone bitmap on the CSR. `Csr.fromEdges` used to
      // consume it only to filter `labelIndex` and then drop it, which
      // lost the delete on the next merge.
      nodeTombstones: nodeTombstones,
    );
  }

  /// Number of labels carried by [vid].
  int labelCountOf(int vid) => labelRowPtr[vid + 1] - labelRowPtr[vid];

  /// True iff [vid] carries [labelId]. O(log k) where k is per-vid
  /// label count (typically 1–4). Allocation-free.
  bool hasLabel(int vid, int labelId) {
    var l = labelRowPtr[vid];
    var r = labelRowPtr[vid + 1];
    while (l < r) {
      final m = (l + r) >>> 1;
      final v = labels[m];
      if (v == labelId) return true;
      if (v < labelId) {
        l = m + 1;
      } else {
        r = m;
      }
    }
    return false;
  }

  /// Zero-copy view over [vid]'s label-id row. Do not mutate.
  Uint32List labelsOf(int vid) =>
      Uint32List.sublistView(labels, labelRowPtr[vid], labelRowPtr[vid + 1]);

  /// Out-degree of [vid].
  int outDegree(int vid) => rowPtrOut[vid + 1] - rowPtrOut[vid];

  /// In-degree of [vid].
  int inDegree(int vid) => rowPtrIn[vid + 1] - rowPtrIn[vid];

  /// Total bytes occupied by the topology arrays.
  ///
  /// Counts `rowPtr` + `colIdx` + `edgeId` + `edgeType` (both directions)
  /// + ragged labels (`labelRowPtr` + `labels`) + the per-label
  /// `labelIndex` arrays + the `eid -> endpoint` maps, at 4 bytes per
  /// `Uint32List` slot, plus 1 byte per [nodeTombstones] entry. Used by
  /// the secondary-index registry to compute the 25-percent soft
  /// warning ratio. PR 1 keeps the legacy [labelOf] field in storage
  /// too; it shares slot count with [labels] under the single-label
  /// invariant and is excluded from the size accounting to avoid
  /// double-counting.
  int get sizeBytes {
    var labelIndexSlots = 0;
    for (final arr in labelIndex.values) {
      labelIndexSlots += arr.length;
    }
    return 4 *
            (rowPtrOut.length +
                colIdxOut.length +
                edgeIdOut.length +
                edgeTypeOut.length +
                rowPtrIn.length +
                colIdxIn.length +
                edgeIdIn.length +
                edgeTypeIn.length +
                labelRowPtr.length +
                labels.length +
                labelIndexSlots +
                eidToSrc.length +
                eidToDst.length) +
        (nodeTombstones?.length ?? 0);
  }
}
