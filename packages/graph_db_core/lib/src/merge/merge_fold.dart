/// Pure overlay-merge fold.
///
/// Takes the current base [Csr] and a frozen [DeltaOverlay] generation,
/// returns a fresh [Csr] with every overlay mutation applied. Pure
/// function — no I/O, no isolate hand-off, no shared state. Top-level
/// so it's a candidate for the worker-isolate fold.
///
/// **Scope.** Full CSR rebuild — copies every edge into a fresh
/// `Uint32List`. Simpler than the per-region segmented fold but
/// stall ∝ edge count. For ≤ 100k edges this is sub-millisecond on
/// AOT. The per-region segmented variant + the `TransferableTypedData`
/// worker hand-off are scheduled as follow-up polish passes.
library;

import 'dart:typed_data';

import '../csr.dart';
import '../overlay/delta_overlay.dart';

/// Folds [overlay] into [base], returns a fresh [Csr].
///
/// Algorithm:
/// 1. Decide `newNodeCount` = max(base.nodeCount, max overlay-added vid + 1).
/// 2. Build `newLabelOf` by extending base.labelOf with overlay
///    additions + applying any label override.
/// 3. Walk the base CSR edge-by-edge, skipping anything in
///    `overlay.deletedEdges` and anything incident on
///    `overlay.deletedNodes`.
/// 4. Append `overlay.addedEdges` (also filtered against
///    `deletedNodes` for nodes deleted in the same generation).
/// 5. Hand the resulting srcs/dsts/edgeTypes/eids to
///    `Csr.fromEdges` (handles the row-pointer build + the parallel
///    reverse CSR + the label index).
Csr foldOverlayIntoCsr({
  required Csr base,
  required DeltaOverlay overlay,
}) {
  // ----- 1. New node count --------------------------------------------------
  var newNodeCount = base.nodeCount;
  for (final vid in overlay.addedNodes.keys) {
    if (vid + 1 > newNodeCount) newNodeCount = vid + 1;
  }

  // ----- 2. Ragged labels (labelRowPtr + labels) ---------------------------
  //
  // Three sources, in priority order: labelOverride (full new set for
  // a pre-existing vid) > addedNodes (overlay-born; authoritative for
  // their vids) > base CSR ragged slice. Build by two passes: count
  // each vid's label width into rowPtr, prefix-sum, then fill.
  final newLabelRowPtr = Uint32List(newNodeCount + 1);
  for (var v = 0; v < newNodeCount; v++) {
    final ov = overlay.labelOverride[v];
    final added = overlay.addedNodes[v];
    final int width;
    if (ov != null) {
      width = ov.length;
    } else if (added != null) {
      width = added.labelIds.length;
    } else if (v < base.nodeCount) {
      width = base.labelCountOf(v);
    } else {
      width = 0;
    }
    newLabelRowPtr[v + 1] = newLabelRowPtr[v] + width;
  }
  final newLabels = Uint32List(newLabelRowPtr[newNodeCount]);
  for (var v = 0; v < newNodeCount; v++) {
    final start = newLabelRowPtr[v];
    final ov = overlay.labelOverride[v];
    final added = overlay.addedNodes[v];
    if (ov != null) {
      final sorted = ov.toList()..sort();
      for (var i = 0; i < sorted.length; i++) {
        newLabels[start + i] = sorted[i];
      }
    } else if (added != null) {
      for (var i = 0; i < added.labelIds.length; i++) {
        newLabels[start + i] = added.labelIds[i];
      }
    } else if (v < base.nodeCount) {
      final view = base.labelsOf(v);
      for (var i = 0; i < view.length; i++) {
        newLabels[start + i] = view[i];
      }
    }
  }
  // PR 1 transitional [labelOf] field — synthesise the first-label
  // scalar so legacy callers that haven't migrated yet still work.
  // PR 4 removes the field; this loop disappears with it.
  final newLabelOf = Uint32List(newNodeCount);
  for (var v = 0; v < newNodeCount; v++) {
    final start = newLabelRowPtr[v];
    final end = newLabelRowPtr[v + 1];
    if (start < end) newLabelOf[v] = newLabels[start];
  }

  // Node-tombstone bitmap fed to Csr.fromEdges so the label index
  // excludes deleted nodes.
  Uint8List? nodeTombstones;
  if (overlay.deletedNodes.isNotEmpty) {
    nodeTombstones = Uint8List(newNodeCount);
    for (final v in overlay.deletedNodes) {
      if (v < newNodeCount) nodeTombstones[v] = 1;
    }
  }

  // ----- 3 + 4. Edge list ---------------------------------------------------
  // Collect surviving base edges + overlay-added edges. Tombstoned
  // edges are skipped; edges incident on deleted nodes are skipped
  // (mirrors the runtime read-filter in MutableGraphState).
  final survivingSrcs = <int>[];
  final survivingDsts = <int>[];
  final survivingTypes = <int>[];
  final survivingEids = <int>[];

  final deletedEdges = overlay.deletedEdges;
  final deletedNodes = overlay.deletedNodes;
  for (var v = 0; v < base.nodeCount; v++) {
    if (deletedNodes.contains(v)) continue;
    final end = base.rowPtrOut[v + 1];
    for (var i = base.rowPtrOut[v]; i < end; i++) {
      final eid = base.edgeIdOut[i];
      if (deletedEdges.contains(eid)) continue;
      final dst = base.colIdxOut[i];
      if (deletedNodes.contains(dst)) continue;
      survivingSrcs.add(v);
      survivingDsts.add(dst);
      survivingTypes.add(base.edgeTypeOut[i]);
      survivingEids.add(eid);
    }
  }
  // Overlay-added edges. Each is keyed by eid in `overlay.addedEdges`.
  for (final entry in overlay.addedEdges.entries) {
    final eid = entry.key;
    final e = entry.value;
    if (deletedEdges.contains(eid)) continue;
    if (deletedNodes.contains(e.src) || deletedNodes.contains(e.dst)) {
      continue;
    }
    survivingSrcs.add(e.src);
    survivingDsts.add(e.dst);
    survivingTypes.add(e.typeId);
    survivingEids.add(eid);
  }

  // Determine the label-id span so `Csr.fromEdges` sizes its
  // labelIndex correctly — walk the ragged `newLabels` so multi-label
  // rows get every bucket counted.
  var labelCount = 0;
  for (final l in newLabels) {
    if (l + 1 > labelCount) labelCount = l + 1;
  }
  for (final l in newLabelOf) {
    if (l + 1 > labelCount) labelCount = l + 1;
  }
  // Also account for any label that exists in the interner but isn't
  // attached to a node (the index slot for it is still allowed) — we
  // can't ask the interner from here (no reference) so we rely on the
  // labels max. If a label was interned but unused, its index bucket
  // simply isn't built; that matches the baseline behaviour.

  return Csr.fromEdges(
    nodeCount: newNodeCount,
    srcs: Uint32List.fromList(survivingSrcs),
    dsts: Uint32List.fromList(survivingDsts),
    edgeTypes: Uint32List.fromList(survivingTypes),
    labelOf: newLabelOf,
    labelRowPtr: newLabelRowPtr,
    labels: newLabels,
    labelCount: labelCount,
    eids: Uint32List.fromList(survivingEids),
    nodeTombstones: nodeTombstones,
  );
}
