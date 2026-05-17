/// Cross-isolate hand-off for the overlay merge (plan §2.3 / §14
/// Phase 2 polish — Spike B port).
///
/// [TransferableTypedData] **moves** the wrapped buffers: the sender
/// loses access on send. To keep the live CSR readable on the main
/// isolate, every wrap **copies** first. That's the SPIKE_B
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
  });

  /// Copies every `Uint32List` of [csr] into a fresh buffer and wraps
  /// the copies in [TransferableTypedData]. The live [csr] keeps its
  /// arrays — only the wrapped copies are moved on send.
  factory TransferableCsr.copyAndWrap(Csr csr) {
    var maxLabel = 0;
    for (final l in csr.labelOf) {
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
    // Rebuild labelIndex from labelOf — cheap (one pass over nodeCount).
    final labelIndex = <int, Uint32List>{};
    final counts = Uint32List(labelCount == 0 ? 1 : labelCount);
    for (var v = 0; v < nodeCount; v++) {
      counts[labelOfM[v]]++;
    }
    for (var l = 0; l < counts.length; l++) {
      labelIndex[l] = Uint32List(counts[l]);
    }
    final fill = Uint32List(counts.length);
    for (var v = 0; v < nodeCount; v++) {
      final l = labelOfM[v];
      labelIndex[l]![fill[l]++] = v;
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

  // Added nodes (v1 single-label, so one label id per node)
  final TransferableTypedData addedNodeVids;
  final TransferableTypedData addedNodeLabels;
  final List<String> addedNodeLogicalIds;

  // Deleted ids
  final TransferableTypedData deletedEdges;
  final TransferableTypedData deletedNodes;

  // Label overrides
  final TransferableTypedData labelOverrideVids;
  final TransferableTypedData labelOverrideLabels;

  TransferableOverlay({
    required this.addedEids,
    required this.addedEdgeSrcs,
    required this.addedEdgeDsts,
    required this.addedEdgeTypes,
    required this.addedEdgeLogicalIds,
    required this.addedNodeVids,
    required this.addedNodeLabels,
    required this.addedNodeLogicalIds,
    required this.deletedEdges,
    required this.deletedNodes,
    required this.labelOverrideVids,
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
    // ----- added nodes
    final anEntries = overlay.addedNodes.entries.toList();
    final anN = anEntries.length;
    final anVids = Uint32List(anN);
    final anLabels = Uint32List(anN);
    final anLogicalIds = <String>[];
    for (var i = 0; i < anN; i++) {
      final e = anEntries[i];
      anVids[i] = e.key;
      anLabels[i] = e.value.labelIds.isEmpty ? 0 : e.value.labelIds.first;
      anLogicalIds.add(e.value.logicalId);
    }
    // ----- deleted
    final delE = Uint32List.fromList(overlay.deletedEdges.toList());
    final delN = Uint32List.fromList(overlay.deletedNodes.toList());
    // ----- label override
    final loEntries = overlay.labelOverride.entries.toList();
    final loVids = Uint32List(loEntries.length);
    final loLabels = Uint32List(loEntries.length);
    for (var i = 0; i < loEntries.length; i++) {
      loVids[i] = loEntries[i].key;
      loLabels[i] = loEntries[i].value;
    }

    return TransferableOverlay(
      addedEids: TransferableTypedData.fromList([aeEids]),
      addedEdgeSrcs: TransferableTypedData.fromList([aeSrcs]),
      addedEdgeDsts: TransferableTypedData.fromList([aeDsts]),
      addedEdgeTypes: TransferableTypedData.fromList([aeTypes]),
      addedEdgeLogicalIds: aeLogicalIds,
      addedNodeVids: TransferableTypedData.fromList([anVids]),
      addedNodeLabels: TransferableTypedData.fromList([anLabels]),
      addedNodeLogicalIds: anLogicalIds,
      deletedEdges: TransferableTypedData.fromList([delE]),
      deletedNodes: TransferableTypedData.fromList([delN]),
      labelOverrideVids: TransferableTypedData.fromList([loVids]),
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
    final anLabels = addedNodeLabels.materialize().asUint32List();
    for (var i = 0; i < anVids.length; i++) {
      out.recordAddNode(
        anVids[i],
        AddedNode(
          logicalId: addedNodeLogicalIds[i],
          labelIds: [anLabels[i]],
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
    final loLabels = labelOverrideLabels.materialize().asUint32List();
    for (var i = 0; i < loVids.length; i++) {
      out.labelOverride[loVids[i]] = loLabels[i];
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
