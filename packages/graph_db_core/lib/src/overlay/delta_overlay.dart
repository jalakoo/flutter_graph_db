/// Per-vid generational delta overlay (plan §3.4).
///
/// All post-load mutations land in this overlay. Reads merge CSR base +
/// overlay inline; a periodic merge (Phase 2E) folds the overlay into a
/// fresh CSR. This v1 file is the **single-segment** form; the
/// per-region segmented overlay (Phase 2E) will sit on top.
///
/// Allocation profile:
/// - Edge-list deltas use `List<int>` (growable) — overlay rebuilds
///   frequently and growable lists amortise better than repeated
///   `Uint32List` re-allocation. The merge step (Phase 2E) packs them
///   into `Uint32List` for the hand-off.
/// - Sets for "removed" are intentionally `Set<int>` (not `List<int>`)
///   so the overlay-aware read path can skip O(n) `.contains` lookups
///   per CSR edge.
library;

/// One added edge in the overlay. `neighbor` is the *other* vid of the
/// edge — for the forward delta keyed by `src`, this is `dst`; for the
/// reverse delta keyed by `dst`, this is `src`.
class OverlayEdge {
  final int neighbor;
  final int eid;
  final int edgeType;
  const OverlayEdge(this.neighbor, this.eid, this.edgeType);

  @override
  String toString() =>
      'OverlayEdge(neighbor=$neighbor, eid=$eid, type=$edgeType)';
}

/// Per-vid edge delta.
///
/// `added` carries new edges into / out of this vid. `removed` carries
/// the **eids** of pre-existing CSR edges that should be hidden — the
/// overlay-aware read path filters these out as it walks the CSR
/// `rowPtr` slice.
class EdgeDelta {
  final List<OverlayEdge> added = [];
  final Set<int> removed = {};

  bool get isEmpty => added.isEmpty && removed.isEmpty;
}

/// Metadata for a node added after CSR construction. Lives in the
/// overlay until the next merge folds it into the CSR base.
class AddedNode {
  final String logicalId;
  final List<int> labelIds;

  AddedNode({required this.logicalId, required this.labelIds});
}

/// Metadata for an edge added after CSR construction. Lives in the
/// overlay until the next merge.
class AddedEdge {
  final String logicalId;
  final int src;
  final int dst;
  final int typeId;

  const AddedEdge({
    required this.logicalId,
    required this.src,
    required this.dst,
    required this.typeId,
  });
}

/// v1 is single-label per node (multi-label is a Phase 1.1 refinement
/// per plan §6.4). Label transitions on pre-existing CSR nodes are
/// represented as a flat `vid -> labelId` override map on the overlay.
/// Reads consult the override first; `null` falls back to
/// `csr.labelOf[vid]`.

/// The single-segment delta overlay (plan §3.4 v1).
///
/// Keys:
/// - [outDelta] / [inDelta]: keyed by vid (works for both pre-existing
///   CSR vids and newly [addedNodes] vids).
/// - [addedNodes]: keyed by vid (always `>= csr.nodeCount` at allocation
///   time, but the overlay does not enforce — the allocator does).
/// - [addedEdges]: keyed by eid.
/// - [deletedNodes] / [deletedEdges]: sets of vids/eids to hide.
/// - [labelDelta]: keyed by vid; only used for pre-existing CSR nodes
///   (newly added nodes have their labels in [AddedNode.labelIds]
///   directly).
class DeltaOverlay {
  final Map<int, EdgeDelta> outDelta = {};
  final Map<int, EdgeDelta> inDelta = {};
  final Map<int, AddedNode> addedNodes = {};
  final Map<int, AddedEdge> addedEdges = {};
  final Set<int> deletedNodes = {};
  final Set<int> deletedEdges = {};
  final Map<int, int> labelOverride = {};

  EdgeDelta _outFor(int vid) => outDelta.putIfAbsent(vid, EdgeDelta.new);
  EdgeDelta _inFor(int vid) => inDelta.putIfAbsent(vid, EdgeDelta.new);

  /// Records a new edge in both forward and reverse buckets.
  void recordAddEdge(AddedEdge edge, int eid) {
    addedEdges[eid] = edge;
    _outFor(edge.src).added.add(OverlayEdge(edge.dst, eid, edge.typeId));
    _inFor(edge.dst).added.add(OverlayEdge(edge.src, eid, edge.typeId));
  }

  /// Hides an edge — either a pre-existing CSR edge or a previously
  /// added overlay edge. For overlay-added edges we also clear the
  /// `added` lists so the bookkeeping stays tight.
  void recordDelEdge(int eid, {required int src, required int dst}) {
    if (addedEdges.remove(eid) != null) {
      _outFor(src).added.removeWhere((e) => e.eid == eid);
      _inFor(dst).added.removeWhere((e) => e.eid == eid);
    } else {
      _outFor(src).removed.add(eid);
      _inFor(dst).removed.add(eid);
    }
    deletedEdges.add(eid);
  }

  /// Records a new node. The vid must already be allocated by the
  /// caller; the overlay only stores the metadata.
  void recordAddNode(int vid, AddedNode node) {
    addedNodes[vid] = node;
  }

  /// Hides a node. Cascade edge removal is the caller's job — the
  /// overlay just records the tombstone.
  void recordDelNode(int vid) {
    deletedNodes.add(vid);
    addedNodes.remove(vid);
    labelOverride.remove(vid);
    outDelta.remove(vid);
    inDelta.remove(vid);
  }

  /// Sets the effective label for [vid] (v1 single-label semantics).
  /// For overlay-added nodes the caller should mutate
  /// [AddedNode.labelIds] in-place instead — that's the authoritative
  /// store for new nodes.
  void recordSetNodeLabel(int vid, int labelId) {
    labelOverride[vid] = labelId;
  }

  bool isNodeDeleted(int vid) => deletedNodes.contains(vid);
  bool isEdgeDeleted(int eid) => deletedEdges.contains(eid);

  /// Are there any pending mutations?
  bool get isEmpty =>
      outDelta.isEmpty &&
      inDelta.isEmpty &&
      addedNodes.isEmpty &&
      addedEdges.isEmpty &&
      deletedNodes.isEmpty &&
      deletedEdges.isEmpty &&
      labelOverride.isEmpty;

  /// Drops every entry. Called by the merge installer after the
  /// overlay has been folded into a fresh CSR.
  void clear() {
    outDelta.clear();
    inDelta.clear();
    addedNodes.clear();
    addedEdges.clear();
    deletedNodes.clear();
    deletedEdges.clear();
    labelOverride.clear();
  }
}
