/// Cross-isolate hand-off for the overlay merge.
///
/// [TransferableTypedData] **moves** the wrapped buffers: the sender
/// loses access on send. To keep the live CSR readable on the main
/// isolate, every wrap **copies** first. That's the
/// "copy-first" design — measured necessary (transfer is destructive)
/// and sufficient (round-trip lossless on native VMs).
///
/// On web there is no real isolate; the coordinator's web fallback
/// folds inline on the main isolate without using this transport.
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../csr.dart';
import '../overlay/delta_overlay.dart';

/// CSR snapshot packed for cross-isolate transfer. Each
/// [TransferableTypedData] is **a copy of the live CSR's array** —
/// the live CSR is never detached.
class TransferableCsr {
  final int nodeCount;
  final int edgeCount;
  final int labelCount;
  final TransferableTypedData rowPtrOut;
  final TransferableTypedData colIdxOut;
  final TransferableTypedData edgeIdOut;
  final TransferableTypedData edgeTypeOut;
  final TransferableTypedData rowPtrIn;
  final TransferableTypedData colIdxIn;
  final TransferableTypedData edgeIdIn;
  final TransferableTypedData edgeTypeIn;
  final TransferableTypedData labelOf;
  // Multi-label rollout PR 2: ragged labels also transferred.
  final TransferableTypedData labelRowPtr;
  final TransferableTypedData labels;

  TransferableCsr({
    required this.nodeCount,
    required this.edgeCount,
    required this.labelCount,
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
  });

  /// Copies every `Uint32List` of [csr] into a fresh buffer and wraps
  /// the copies in [TransferableTypedData]. The live [csr] keeps its
  /// arrays — only the wrapped copies are moved on send.
  factory TransferableCsr.copyAndWrap(Csr csr) {
    var maxLabel = 0;
    for (final l in csr.labels) {
      if (l + 1 > maxLabel) maxLabel = l + 1;
    }
    return TransferableCsr(
      nodeCount: csr.nodeCount,
      edgeCount: csr.edgeCount,
      labelCount: maxLabel,
      rowPtrOut: _wrapCopy(csr.rowPtrOut),
      colIdxOut: _wrapCopy(csr.colIdxOut),
      edgeIdOut: _wrapCopy(csr.edgeIdOut),
      edgeTypeOut: _wrapCopy(csr.edgeTypeOut),
      rowPtrIn: _wrapCopy(csr.rowPtrIn),
      colIdxIn: _wrapCopy(csr.colIdxIn),
      edgeIdIn: _wrapCopy(csr.edgeIdIn),
      edgeTypeIn: _wrapCopy(csr.edgeTypeIn),
      labelOf: _wrapCopy(csr.labelOf),
      labelRowPtr: _wrapCopy(csr.labelRowPtr),
      labels: _wrapCopy(csr.labels),
    );
  }

  static TransferableTypedData _wrapCopy(Uint32List src) =>
      TransferableTypedData.fromList([Uint32List.fromList(src)]);

  /// Reconstructs a [Csr] on the receiving side. Each
  /// `materialize()` may be called exactly once.
  Csr materialize() {
    final rowPtrOutM = rowPtrOut.materialize().asUint32List();
    final colIdxOutM = colIdxOut.materialize().asUint32List();
    final edgeIdOutM = edgeIdOut.materialize().asUint32List();
    final edgeTypeOutM = edgeTypeOut.materialize().asUint32List();
    final rowPtrInM = rowPtrIn.materialize().asUint32List();
    final colIdxInM = colIdxIn.materialize().asUint32List();
    final edgeIdInM = edgeIdIn.materialize().asUint32List();
    final edgeTypeInM = edgeTypeIn.materialize().asUint32List();
    final labelOfM = labelOf.materialize().asUint32List();
    final labelRowPtrM = labelRowPtr.materialize().asUint32List();
    final labelsM = labels.materialize().asUint32List();
    // Rebuild labelIndex from the ragged labels.
    final effLabelCount = labelCount == 0 ? 1 : labelCount;
    final counts = Uint32List(effLabelCount);
    for (var v = 0; v < nodeCount; v++) {
      final end = labelRowPtrM[v + 1];
      for (var i = labelRowPtrM[v]; i < end; i++) {
        final l = labelsM[i];
        if (l < effLabelCount) counts[l]++;
      }
    }
    final labelIndex = <int, Uint32List>{};
    for (var l = 0; l < effLabelCount; l++) {
      labelIndex[l] = Uint32List(counts[l]);
    }
    final fill = Uint32List(effLabelCount);
    for (var v = 0; v < nodeCount; v++) {
      final end = labelRowPtrM[v + 1];
      for (var i = labelRowPtrM[v]; i < end; i++) {
        final l = labelsM[i];
        if (l < effLabelCount) labelIndex[l]![fill[l]++] = v;
      }
    }
    return Csr(
      nodeCount: nodeCount,
      edgeCount: edgeCount,
      rowPtrOut: rowPtrOutM,
      colIdxOut: colIdxOutM,
      edgeIdOut: edgeIdOutM,
      edgeTypeOut: edgeTypeOutM,
      rowPtrIn: rowPtrInM,
      colIdxIn: colIdxInM,
      edgeIdIn: edgeIdInM,
      edgeTypeIn: edgeTypeInM,
      labelOf: labelOfM,
      labelRowPtr: labelRowPtrM,
      labels: labelsM,
      labelIndex: labelIndex,
    );
  }
}

/// Flattened overlay packed for cross-isolate transfer.
///
/// `addedEdges`, `addedNodes`, `labelOverride` are split into parallel
/// arrays. Strings travel as plain `List<String>` (Dart sends them
/// across isolates by deep copy — no `TransferableTypedData` needed).
/// `outDelta` / `inDelta` are **not** transferred — the fold rebuilds
/// them from `addedEdges` (they are read-path indexes, not part of
/// the canonical state).
class TransferableOverlay {
  // Added edges
  final TransferableTypedData addedEids;
  final TransferableTypedData addedEdgeSrcs;
  final TransferableTypedData addedEdgeDsts;
  final TransferableTypedData addedEdgeTypes;
  final List<String> addedEdgeLogicalIds;

  // Added nodes — ragged labels (PR 2): one row per node into
  // addedNodeLabels via addedNodeLabelRowPtr.
  final TransferableTypedData addedNodeVids;
  final TransferableTypedData addedNodeLabelRowPtr;
  final TransferableTypedData addedNodeLabels;
  final List<String> addedNodeLogicalIds;

  // Deleted ids
  final TransferableTypedData deletedEdges;
  final TransferableTypedData deletedNodes;

  // Label overrides — ragged sets (PR 2): one row per overridden vid
  // into labelOverrideLabels via labelOverrideRowPtr.
  final TransferableTypedData labelOverrideVids;
  final TransferableTypedData labelOverrideRowPtr;
  final TransferableTypedData labelOverrideLabels;

  TransferableOverlay({
    required this.addedEids,
    required this.addedEdgeSrcs,
    required this.addedEdgeDsts,
    required this.addedEdgeTypes,
    required this.addedEdgeLogicalIds,
    required this.addedNodeVids,
    required this.addedNodeLabelRowPtr,
    required this.addedNodeLabels,
    required this.addedNodeLogicalIds,
    required this.deletedEdges,
    required this.deletedNodes,
    required this.labelOverrideVids,
    required this.labelOverrideRowPtr,
    required this.labelOverrideLabels,
  });

  factory TransferableOverlay.copyAndWrap(DeltaOverlay overlay) {
    // ----- added edges
    final aeEntries = overlay.addedEdges.entries.toList();
    final aeN = aeEntries.length;
    final aeEids = Uint32List(aeN);
    final aeSrcs = Uint32List(aeN);
    final aeDsts = Uint32List(aeN);
    final aeTypes = Uint32List(aeN);
    final aeLogicalIds = <String>[];
    for (var i = 0; i < aeN; i++) {
      final e = aeEntries[i];
      aeEids[i] = e.key;
      aeSrcs[i] = e.value.src;
      aeDsts[i] = e.value.dst;
      aeTypes[i] = e.value.typeId;
      aeLogicalIds.add(e.value.logicalId);
    }
    // ----- added nodes (ragged labels)
    final anEntries = overlay.addedNodes.entries.toList();
    final anN = anEntries.length;
    final anVids = Uint32List(anN);
    final anLabelRowPtr = Uint32List(anN + 1);
    final anLogicalIds = <String>[];
    var anTotalLabels = 0;
    for (var i = 0; i < anN; i++) {
      anTotalLabels += anEntries[i].value.labelIds.length;
    }
    final anLabels = Uint32List(anTotalLabels);
    var cursor = 0;
    for (var i = 0; i < anN; i++) {
      final e = anEntries[i];
      anVids[i] = e.key;
      anLogicalIds.add(e.value.logicalId);
      for (final l in e.value.labelIds) {
        anLabels[cursor++] = l;
      }
      anLabelRowPtr[i + 1] = cursor;
    }
    // ----- deleted
    final delE = Uint32List.fromList(overlay.deletedEdges.toList());
    final delN = Uint32List.fromList(overlay.deletedNodes.toList());
    // ----- label override (ragged sets)
    final loEntries = overlay.labelOverride.entries.toList();
    final loN = loEntries.length;
    final loVids = Uint32List(loN);
    final loRowPtr = Uint32List(loN + 1);
    var loTotal = 0;
    for (var i = 0; i < loN; i++) {
      loTotal += loEntries[i].value.length;
    }
    final loLabels = Uint32List(loTotal);
    var loCursor = 0;
    for (var i = 0; i < loN; i++) {
      loVids[i] = loEntries[i].key;
      // Sort the set so the receiver doesn't have to.
      final sorted = loEntries[i].value.toList()..sort();
      for (final l in sorted) {
        loLabels[loCursor++] = l;
      }
      loRowPtr[i + 1] = loCursor;
    }

    return TransferableOverlay(
      addedEids: TransferableTypedData.fromList([aeEids]),
      addedEdgeSrcs: TransferableTypedData.fromList([aeSrcs]),
      addedEdgeDsts: TransferableTypedData.fromList([aeDsts]),
      addedEdgeTypes: TransferableTypedData.fromList([aeTypes]),
      addedEdgeLogicalIds: aeLogicalIds,
      addedNodeVids: TransferableTypedData.fromList([anVids]),
      addedNodeLabelRowPtr: TransferableTypedData.fromList([anLabelRowPtr]),
      addedNodeLabels: TransferableTypedData.fromList([anLabels]),
      addedNodeLogicalIds: anLogicalIds,
      deletedEdges: TransferableTypedData.fromList([delE]),
      deletedNodes: TransferableTypedData.fromList([delN]),
      labelOverrideVids: TransferableTypedData.fromList([loVids]),
      labelOverrideRowPtr: TransferableTypedData.fromList([loRowPtr]),
      labelOverrideLabels: TransferableTypedData.fromList([loLabels]),
    );
  }

  /// Reconstructs a [DeltaOverlay] on the receiving side.
  DeltaOverlay materialize() {
    final out = DeltaOverlay();
    final aeEids = addedEids.materialize().asUint32List();
    final aeSrcs = addedEdgeSrcs.materialize().asUint32List();
    final aeDsts = addedEdgeDsts.materialize().asUint32List();
    final aeTypes = addedEdgeTypes.materialize().asUint32List();
    for (var i = 0; i < aeEids.length; i++) {
      out.recordAddEdge(
        AddedEdge(
          logicalId: addedEdgeLogicalIds[i],
          src: aeSrcs[i],
          dst: aeDsts[i],
          typeId: aeTypes[i],
        ),
        aeEids[i],
      );
    }
    final anVids = addedNodeVids.materialize().asUint32List();
    final anRowPtr = addedNodeLabelRowPtr.materialize().asUint32List();
    final anLabels = addedNodeLabels.materialize().asUint32List();
    for (var i = 0; i < anVids.length; i++) {
      final labels = <int>[
        for (var j = anRowPtr[i]; j < anRowPtr[i + 1]; j++) anLabels[j],
      ];
      out.recordAddNode(
        anVids[i],
        AddedNode(
          logicalId: addedNodeLogicalIds[i],
          labelIds: labels,
        ),
      );
    }
    final delE = deletedEdges.materialize().asUint32List();
    for (final e in delE) {
      out.deletedEdges.add(e);
    }
    final delN = deletedNodes.materialize().asUint32List();
    for (final v in delN) {
      out.deletedNodes.add(v);
    }
    final loVids = labelOverrideVids.materialize().asUint32List();
    final loRowPtr = labelOverrideRowPtr.materialize().asUint32List();
    final loLabels = labelOverrideLabels.materialize().asUint32List();
    for (var i = 0; i < loVids.length; i++) {
      final set = <int>{
        for (var j = loRowPtr[i]; j < loRowPtr[i + 1]; j++) loLabels[j],
      };
      out.labelOverride[loVids[i]] = set;
    }
    return out;
  }
}

/// Task sent main → worker.
class MergeTask {
  final TransferableCsr csr;
  final TransferableOverlay overlay;
  MergeTask({required this.csr, required this.overlay});
}

/// Result sent worker → main.
class MergeResult {
  final TransferableCsr csr;
  final int computeUs;
  MergeResult({required this.csr, required this.computeUs});
}
