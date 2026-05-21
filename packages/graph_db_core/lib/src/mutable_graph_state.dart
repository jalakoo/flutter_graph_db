import 'dart:math' as math;
import 'dart:typed_data';

import 'constraints/constraint.dart';
import 'constraints/constraint_catalog.dart';
import 'csr.dart';
import 'exceptions.dart';
import 'ids.dart';
import 'merge/merge_coordinator.dart';
import 'merge/merge_fold.dart';
import 'overlay/delta_overlay.dart';
import 'prop_value.dart';
import 'property_store.dart';
import 'secondary_index/index_size_event.dart';
import 'secondary_index/index_spec.dart';
import 'secondary_index/index_worker.dart';
import 'secondary_index/secondary_index.dart';
import 'string_interner.dart';
import 'wal_op.dart' show ConstraintKind;

/// The composed in-memory state the engine reads from.
///
/// Built once from a fixture via [MutableGraphState.fromFixture], with
/// the mutation path layered on top via the `apply(WalOp)` applicator,
/// the delta overlay, and the WAL.
///
/// Read primitives live here as thin wrappers over the underlying [Csr]
/// + [PropertyStore]. The `outRangeStart` / `outRangeEnd` pair is the
/// **primitive range read API** — allocation-free, the simplest, and
/// the fastest on AOT.
class MutableGraphState {
  final StringInterner strings;
  Csr _csr;
  final PropertyStore nodeProps;
  final PropertyStore edgeProps;
  final DeltaOverlay overlay;

  /// Current CSR. Re-bound by [installMergedCsr] when the overlay
  /// folds into a fresh CSR. Callers that cache the reference across
  /// an `await` should re-read after the await — same shape as
  /// `state.csr` outside a transaction.
  Csr get csr => _csr;

  /// Eid -> source vid (within the CSR base only). Rebuilt by
  /// [installMergedCsr]. Used by [applyDelEdge] to resolve a
  /// base-CSR edge's endpoints without a linear scan.
  Uint32List _baseCsrEidToSrc;
  Uint32List get baseCsrEidToSrc => _baseCsrEidToSrc;

  /// Eid -> destination vid (within the CSR base only). Rebuilt by
  /// [installMergedCsr].
  Uint32List _baseCsrEidToDst;
  Uint32List get baseCsrEidToDst => _baseCsrEidToDst;

  /// Soft merge trigger override. When `null`, the formula
  /// `max(10_000, 5 % of csr.edgeCount)` is used. Tests set a small
  /// value to force a merge after a handful of mutations.
  int? mergeThreshold;

  /// Optional worker-isolate merge coordinator. When set,
  /// [maybeMergeOverlayAsync] hands the fold off to the worker and
  /// the main-isolate stall is only the copy + install cost. When
  /// `null`, the same call falls back to the synchronous [mergeNow]
  /// path. Set via `MergeCoordinator.spawn()` and assign before any
  /// merge would fire.
  MergeCoordinator? mergeCoordinator;

  /// Optional worker-isolate index-rebuild coordinator. When set,
  /// [flushDeferredIndexUpdatesAsync] hands rebuilds off to the
  /// worker (supported column types only — int_ today; other types
  /// fall back to main-isolate rebuild). When `null`, the same async
  /// call runs the rebuild inline.
  IndexRebuildCoordinator? indexRebuildCoordinator;

  /// Constraint catalog. Rebuilt from the
  /// WAL on recovery via the `DeclareConstraint` / `DropConstraint`
  /// ops. Application code reads this to introspect active
  /// constraints; mutations enforce against it automatically.
  final ConstraintCatalog constraints = ConstraintCatalog();

  int _nextVid;
  int _nextEid;

  /// LSN assigned to the next [SequencedWalOp]. Today this is a
  /// simple counter; a future variant may replace it with the WAL
  /// byte offset.
  int _nextLsn;

  /// Txn id assigned to the next transaction. A simple counter today;
  /// future variants may have the WAL header carry the highest txn id
  /// for recovery to resume from.
  int _nextTxnId;

  /// The currently-active txn id, or `null` if no txn is in flight.
  /// The engine is single-writer — a second `runTransaction` while
  /// [activeTxnId] is non-null throws.
  int? activeTxnId;

  MutableGraphState({
    required this.strings,
    required Csr csr,
    required this.nodeProps,
    required this.edgeProps,
    DeltaOverlay? overlay,
    int? nextVid,
    int? nextEid,
    int nextLsn = 0,
    int nextTxnId = 1,
    this.mergeThreshold,
  })  : _csr = csr,
        overlay = overlay ?? DeltaOverlay(),
        _nextVid = nextVid ?? csr.nodeCount,
        _nextEid = nextEid ?? csr.edgeCount,
        _nextLsn = nextLsn,
        _nextTxnId = nextTxnId,
        _baseCsrEidToSrc = _buildEidToSrc(csr),
        _baseCsrEidToDst = _buildEidToDst(csr);

  static Uint32List _buildEidToSrc(Csr csr) {
    // eids are sparse (deletions leave gaps), so size to max+1, not
    // edgeCount — `out[eid]` must be a legal write for every eid
    // present in `csr.edgeIdOut`.
    final out = Uint32List(_maxEid(csr) + 1);
    for (var v = 0; v < csr.nodeCount; v++) {
      final end = csr.rowPtrOut[v + 1];
      for (var i = csr.rowPtrOut[v]; i < end; i++) {
        out[csr.edgeIdOut[i]] = v;
      }
    }
    return out;
  }

  static Uint32List _buildEidToDst(Csr csr) {
    final out = Uint32List(_maxEid(csr) + 1);
    for (var v = 0; v < csr.nodeCount; v++) {
      final end = csr.rowPtrOut[v + 1];
      for (var i = csr.rowPtrOut[v]; i < end; i++) {
        out[csr.edgeIdOut[i]] = csr.colIdxOut[i];
      }
    }
    return out;
  }

  static int _maxEid(Csr csr) {
    var maxEid = 0;
    final eids = csr.edgeIdOut;
    for (var i = 0; i < eids.length; i++) {
      if (eids[i] > maxEid) maxEid = eids[i];
    }
    return maxEid;
  }

  /// Next vid the allocator will issue. Read-only; mutate via
  /// [allocVid] (or have the applicator fast-forward via [applyAddNode]).
  int get nextVid => _nextVid;

  /// Next eid the allocator will issue. Read-only; mutate via
  /// [allocEid] (or have the applicator fast-forward via [applyAddEdge]).
  int get nextEid => _nextEid;

  /// Next LSN the WAL pipeline will issue. Read-only; mutate via
  /// [allocLsn].
  int get nextLsn => _nextLsn;

  /// Next txn id the runtime will issue. Read-only; mutate via
  /// [allocTxnId].
  int get nextTxnId => _nextTxnId;

  /// Returns a fresh monotonic LSN and bumps the counter.
  int allocLsn() => _nextLsn++;

  /// Returns a fresh monotonic txn id and bumps the counter.
  int allocTxnId() => _nextTxnId++;

  // ----- Merge trigger ---------------------------

  /// Total overlay mutation count. Threshold metric for the merge
  /// trigger`).
  int get overlayMutationCount =>
      overlay.addedEdges.length + overlay.deletedEdges.length;

  /// Effective merge threshold. Honors [mergeThreshold] if set;
  /// otherwise the formula `max(10_000, 5 % of csr.edgeCount)`.
  int get effectiveMergeThreshold =>
      mergeThreshold ?? math.max(10000, (csr.edgeCount * 0.05).toInt());

  /// True when the overlay has grown past [effectiveMergeThreshold].
  bool get shouldMerge =>
      overlayMutationCount >= effectiveMergeThreshold;

  /// Folds [overlay] into a fresh CSR and installs it via
  /// [installMergedCsr]. **Synchronous** main-isolate fold; the
  /// worker-isolate hand-off is a follow-up — the merge-stall <1 ms
  /// acceptance metric requires it for graphs much larger than the
  /// 100 k bench fixture.
  void mergeNow() {
    if (overlay.isEmpty) return;
    final fresh = foldOverlayIntoCsr(base: _csr, overlay: overlay);
    installMergedCsr(fresh);
  }

  /// Convenience — runs [mergeNow] if [shouldMerge] is true; returns
  /// whether a merge was performed. Wired into `GraphDb._commit` so
  /// every transaction commit pays the threshold check.
  bool maybeMergeOverlay() {
    if (!shouldMerge) return false;
    mergeNow();
    return true;
  }

  /// Async variant — uses [mergeCoordinator] (worker isolate) when
  /// set, otherwise falls back to [mergeNow]. Main-isolate stall in
  /// the worker path is bounded by copy + install (the fold runs
  /// off-main). acceptance metric: `< 1 ms` p99 stall.
  Future<bool> maybeMergeOverlayAsync() async {
    if (!shouldMerge) return false;
    final coord = mergeCoordinator;
    if (coord == null) {
      mergeNow();
      return true;
    }
    // `coord.merge` copies the live CSR + overlay (main-isolate cost),
    // awaits the worker fold, returns the fresh CSR. Install is a
    // pointer-swap.
    final fresh = await coord.merge(_csr, overlay);
    installMergedCsr(fresh);
    return true;
  }

  /// Replaces the current CSR with [newCsr] and clears the overlay.
  /// Called by [mergeNow]; exposed publicly so tests + the worker
  /// follow-up can install a CSR built off-main.
  void installMergedCsr(Csr newCsr) {
    _csr = newCsr;
    _baseCsrEidToSrc = _buildEidToSrc(newCsr);
    _baseCsrEidToDst = _buildEidToDst(newCsr);
    overlay.clear();
  }

  /// Builds an in-memory state from a synthetic / loader edge list.
  ///
  /// `labelNames` and `edgeTypeNames` are interned up front so the
  /// `labelOf` and `edgeTypes` arrays can be filled with the resulting
  /// ids by the caller.
  ///
  /// [eids] and [nodeTombstones] are forwarded to [Csr.fromEdges] —
  /// callers that filter deleted entries from `srcs`/`dsts` while keeping
  /// the original vid/eid numbering use these.
  ///
  /// [vidSpace] / [eidSpace] override the size of the underlying property
  /// stores. Defaults track the input but allow headroom for growth
  /// (handy for example apps that mutate after loading a fixture).
  factory MutableGraphState.fromFixture({
    required int nodeCount,
    required Uint32List srcs,
    required Uint32List dsts,
    required Uint32List edgeTypes,
    required Uint32List labelOf,
    required List<String> labelNames,
    required List<String> edgeTypeNames,
    Uint32List? eids,
    Uint8List? nodeTombstones,
    int? vidSpace,
    int? eidSpace,
  }) {
    final strings = StringInterner();
    for (final name in labelNames) {
      strings.internLabel(name);
    }
    for (final name in edgeTypeNames) {
      strings.internEdgeType(name);
    }
    final csr = Csr.fromEdges(
      nodeCount: nodeCount,
      srcs: srcs,
      dsts: dsts,
      edgeTypes: edgeTypes,
      labelOf: labelOf,
      labelCount: labelNames.length,
      eids: eids,
      nodeTombstones: nodeTombstones,
    );
    final effectiveVidSpace = vidSpace ?? nodeCount;
    final effectiveEidSpace = eidSpace ??
        (eids != null && eids.isNotEmpty
            ? (eids.reduce((a, b) => a > b ? a : b) + 1)
            : csr.edgeCount);
    return MutableGraphState(
      strings: strings,
      csr: csr,
      nodeProps: PropertyStore(vidSpace: effectiveVidSpace),
      edgeProps: PropertyStore(vidSpace: effectiveEidSpace),
    );
  }

  // ----- Topology reads — primitive range API -----------
  //
  // Caller indexes the shared CSR arrays directly through the `at`
  // accessors. Allocation-free.

  /// Start index of [vid]'s outgoing edges inside [csr.colIdxOut] /
  /// [csr.edgeIdOut] / [csr.edgeTypeOut].
  int outStart(Vid vid) => csr.rowPtrOut[vid.value];

  /// End index (exclusive) of [vid]'s outgoing edges.
  int outEnd(Vid vid) => csr.rowPtrOut[vid.value + 1];

  /// Out-neighbour vid at CSR position [i].
  Vid outNeighborAt(int i) => Vid(csr.colIdxOut[i]);

  /// Edge id at CSR position [i].
  Eid edgeIdAt(int i) => Eid(csr.edgeIdOut[i]);

  /// Edge type id at CSR position [i] (interned via [strings]).
  int edgeTypeAt(int i) => csr.edgeTypeOut[i];

  /// Start index of [vid]'s incoming edges inside the reverse CSR.
  int inStart(Vid vid) => csr.rowPtrIn[vid.value];

  /// End index (exclusive) of [vid]'s incoming edges.
  int inEnd(Vid vid) => csr.rowPtrIn[vid.value + 1];

  /// Incoming neighbour (source) vid at reverse-CSR position [i].
  Vid inNeighborAt(int i) => Vid(csr.colIdxIn[i]);

  /// Edge id at reverse-CSR position [i].
  Eid inEdgeIdAt(int i) => Eid(csr.edgeIdIn[i]);

  /// Edge type at reverse-CSR position [i].
  int inEdgeTypeAt(int i) => csr.edgeTypeIn[i];

  /// All vids carrying [labelId], in ascending order. Allocation-free
  /// (returns a view into a pre-built sorted index).
  Uint32List labelScan(int labelId) =>
      csr.labelIndex[labelId] ?? _emptyU32;

  /// Overlay-aware label scan — all vids that *effectively* carry
  /// [labelId], in ascending order (read-your-writes). When the overlay
  /// is empty this is the zero-copy CSR index view (identical instance to
  /// [labelScan]); when writes are pending it folds the overlay in (base
  /// index − tombstones − dropped overrides + overlay-added nodes +
  /// gained overrides, via [_forEachVidWithLabel]) and returns a
  /// freshly-sorted copy. The public `GraphDb.labelScan` routes here so
  /// committed mutations are visible without an explicit `mergeNow()`.
  Uint32List effectiveLabelScan(int labelId) {
    if (overlay.isEmpty) return csr.labelIndex[labelId] ?? _emptyU32;
    final out = <int>[];
    _forEachVidWithLabel(labelId, out.add);
    out.sort();
    return Uint32List.fromList(out);
  }

  static final Uint32List _emptyU32 = Uint32List(0);

  // ----- Property reads — raw primitives -----------------------

  bool hasNodeProp(Vid vid, int keyId) =>
      nodeProps.has(vid.value, keyId);
  int getNodeIntProp(Vid vid, int keyId) =>
      nodeProps.getInt(vid.value, keyId);
  double getNodeDoubleProp(Vid vid, int keyId) =>
      nodeProps.getDouble(vid.value, keyId);
  bool getNodeBoolProp(Vid vid, int keyId) =>
      nodeProps.getBool(vid.value, keyId);
  String getNodeStringProp(Vid vid, int keyId) =>
      nodeProps.getString(vid.value, keyId);
  int getNodeStringIdProp(Vid vid, int keyId) =>
      nodeProps.getStringId(vid.value, keyId);

  bool hasEdgeProp(Eid eid, int keyId) =>
      edgeProps.has(eid.value, keyId);
  int getEdgeIntProp(Eid eid, int keyId) =>
      edgeProps.getInt(eid.value, keyId);
  double getEdgeDoubleProp(Eid eid, int keyId) =>
      edgeProps.getDouble(eid.value, keyId);
  bool getEdgeBoolProp(Eid eid, int keyId) =>
      edgeProps.getBool(eid.value, keyId);
  String getEdgeStringProp(Eid eid, int keyId) =>
      edgeProps.getString(eid.value, keyId);
  int getEdgeStringIdProp(Eid eid, int keyId) =>
      edgeProps.getStringId(eid.value, keyId);

  // ----- Allocators -------------------------

  /// Returns a fresh [Vid] and grows [nodeProps] so the new vid can
  /// hold properties. Bumps [nextVid]. Transaction builders call this
  /// before constructing an `AddNode` WalOp.
  Vid allocVid() {
    final v = _nextVid++;
    _ensureNodeCapacity(v);
    return Vid(v);
  }

  /// Returns a fresh [Eid] and grows [edgeProps] so the new eid can
  /// hold properties. Bumps [nextEid].
  Eid allocEid() {
    final e = _nextEid++;
    _ensureEdgeCapacity(e);
    return Eid(e);
  }

  void _ensureNodeCapacity(int vid) {
    if (vid >= nodeProps.vidSpace) {
      var newSize = nodeProps.vidSpace == 0 ? 16 : nodeProps.vidSpace;
      while (newSize <= vid) {
        newSize *= 2;
      }
      nodeProps.growVidSpace(newSize);
    }
  }

  void _ensureEdgeCapacity(int eid) {
    if (eid >= edgeProps.vidSpace) {
      var newSize = edgeProps.vidSpace == 0 ? 16 : edgeProps.vidSpace;
      while (newSize <= eid) {
        newSize *= 2;
      }
      edgeProps.growVidSpace(newSize);
    }
  }

  // ----- Mutation appliers ----------
  //
  // These are the methods the applicator (`apply()`) routes WalOp arms
  // to. Transaction builders call [allocVid] / [allocEid] first to
  // assign ids, then construct the WalOp, then feed it through `apply`.
  //
  // Writes land in the [DeltaOverlay] (or directly in [PropertyStore]
  // for property ops, since the property store has no overlay layer —
  // values are mutable in place). The WAL sink persists these calls,
  // and a worker-isolate merge folds the overlay back into the CSR
  // base.

  /// Applies an `AddNode` WAL op. Fast-forwards [nextVid] so future
  /// allocations stay monotonic even when [vid] was minted elsewhere
  /// (recovery, sync replay).
  void applyAddNode(
    Vid vid, {
    required String logicalId,
    required List<int> labelIds,
    required Map<int, PropValue> props,
  }) {
    if (overlay.deletedNodes.contains(vid.value)) {
      throw ConstraintViolation(
          'cannot AddNode at vid ${vid.value}: already tombstoned '
          '(vids are never reused)');
    }
    if (vid.value >= _nextVid) {
      _nextVid = vid.value + 1;
      _ensureNodeCapacity(vid.value);
    }
    if (labelIds.isEmpty) {
      throw ConstraintViolation(
          'AddNode requires at least one label id');
    }
    // Defensive dedupe + sort — caller bug shouldn't corrupt the
    // sorted-ascending row invariant (`Csr.hasLabel` relies on it).
    final sortedLabels = (Set<int>.of(labelIds).toList())..sort();
    // Existence-constraint pre-check — fail before any property
    // writes so partial state isn't left behind. Applies per-label
    // (Neo4j-aligned: a constraint on L applies to any node carrying L).
    for (final labelId in sortedLabels) {
      constraints.enforceExistenceOnAddNode(
        labelId: labelId,
        props: props,
      );
    }
    overlay.recordAddNode(
      vid.value,
      AddedNode(logicalId: logicalId, labelIds: sortedLabels),
    );
    // Pre-check unique constraints across the whole prop bundle so
    // partial writes aren't left behind on rejection.
    for (final e in props.entries) {
      _enforceUniqueNodeIndex(vid.value, e.key, e.value);
    }
    for (final e in props.entries) {
      _writeNodeProp(vid.value, e.key, e.value);
    }
    // Indexes covering any written key need re-derivation.
    final touchedKeys = props.keys.toSet();
    for (final k in touchedKeys) {
      _maintainNodeIndexes(vid.value, k);
    }
  }

  /// Applies a `DelNode` WAL op. Cascades — every incident edge
  /// (forward + reverse, CSR base + overlay added) is also marked
  /// deleted.
  void applyDelNode(Vid vid) {
    if (!_nodeExists(vid.value)) return; // idempotent
    // Snapshot incident eids first so the iteration is stable while
    // we mutate the overlay underneath.
    final outEids = <int>[];
    forEachOutEdge(vid, (e, _, __) => outEids.add(e.value));
    final inEids = <int>[];
    forEachInEdge(vid, (e, _, __) => inEids.add(e.value));
    for (final e in outEids) {
      applyDelEdge(Eid(e));
    }
    for (final e in inEids) {
      applyDelEdge(Eid(e));
    }
    overlay.recordDelNode(vid.value);
    // Properties of a deleted node are also gone — tombstone them
    // in the columnar store so the index rebuild doesn't pick them
    // up.
    nodeProps.removeAllForVid(vid.value);
    // A deleted vid disappears from every index that covered it —
    // rebuild every node index (incremental int indexes drop the
    // vid in O(1) without a full rebuild).
    _maintainAllNodeIndexes(deletedVid: vid.value);
  }

  /// Applies a `SetNodeLabels` WAL op. Merges [added] into and removes
  /// [removed] from the node's current effective label set. Idempotent
  /// — re-adding a label already present or removing one already
  /// absent is a no-op for that element.
  ///
  /// Throws [ConstraintViolation] if:
  /// - [added] and [removed] intersect (caller bug — disjoint inputs
  ///   required).
  /// - The resulting set would be empty (per §4.6 of the multi-label
  ///   plan — every node carries at least one label).
  ///
  /// Re-validates existence + unique constraints for every label in
  /// `added ∪ removed`.
  void applySetNodeLabels(
    Vid vid, {
    required List<int> added,
    required List<int> removed,
  }) {
    if (!_nodeExists(vid.value)) {
      throw NotFoundException('SetNodeLabels on absent vid ${vid.value}');
    }
    final addedSet = Set<int>.of(added);
    final removedSet = Set<int>.of(removed);
    final intersection = addedSet.intersection(removedSet);
    if (intersection.isNotEmpty) {
      throw ConstraintViolation(
          'SetNodeLabels: added and removed intersect on $intersection');
    }
    // Compute the new effective set. Seed from the current effective
    // labels (overlay-added node → in-place; override → existing set;
    // base CSR → ragged labels view).
    final newSet = <int>{};
    final addedNode = overlay.addedNodes[vid.value];
    if (addedNode != null) {
      newSet.addAll(addedNode.labelIds);
    } else if (overlay.labelOverride.containsKey(vid.value)) {
      newSet.addAll(overlay.labelOverride[vid.value]!);
    } else {
      for (final id in csr.labelsOf(vid.value)) {
        newSet.add(id);
      }
    }
    newSet.removeAll(removedSet);
    newSet.addAll(addedSet);
    if (newSet.isEmpty) {
      throw ConstraintViolation(
          'SetNodeLabels would empty the label set for vid ${vid.value}; '
          'every node must carry at least one label');
    }
    // Existence-constraint re-check: every label being *added* may pull
    // the node under a new existence constraint's scope. Removed labels
    // can only release constraints — never trigger them — so this loop
    // only covers added.
    for (final labelId in addedSet) {
      constraints.enforceExistenceOnAddNodeLabel(
        vid: vid.value,
        labelId: labelId,
        hasProp: (keyId) => nodeProps.has(vid.value, keyId),
      );
    }
    // Persist into the overlay. Overlay-added node = mutate
    // AddedNode.labelIds in place (sorted ascending); pre-existing CSR
    // node = labelOverride set.
    if (addedNode != null) {
      addedNode.labelIds
        ..clear()
        ..addAll(newSet.toList()..sort());
    } else {
      overlay.recordSetNodeLabels(vid.value, newSet);
    }
  }

  /// Applies a `SetNodeProp` WAL op.
  void applySetNodeProp(Vid vid, int keyId, PropValue value) {
    if (!_nodeExists(vid.value)) {
      throw NotFoundException('SetNodeProp on absent vid ${vid.value}');
    }
    _enforceUniqueNodeIndex(vid.value, keyId, value);
    _writeNodeProp(vid.value, keyId, value);
    _maintainNodeIndexes(vid.value, keyId);
  }

  /// Applies a `DelNodeProp` WAL op.
  void applyDelNodeProp(Vid vid, int keyId) {
    constraints.enforceExistenceOnDelNodeProp(
      vid: vid.value,
      keyId: keyId,
      hasLabel: (v, l) => hasLabelEffective(Vid(v), l),
    );
    nodeProps.remove(vid.value, keyId);
    _maintainNodeIndexes(vid.value, keyId);
  }

  /// Applies an `AddEdge` WAL op. Fast-forwards [nextEid].
  void applyAddEdge(
    Eid eid, {
    required String logicalId,
    required Vid src,
    required Vid dst,
    required int typeId,
    required Map<int, PropValue> props,
  }) {
    if (overlay.deletedEdges.contains(eid.value)) {
      throw ConstraintViolation(
          'cannot AddEdge at eid ${eid.value}: already tombstoned '
          '(eids are never reused)');
    }
    if (eid.value >= _nextEid) {
      _nextEid = eid.value + 1;
      _ensureEdgeCapacity(eid.value);
    }
    if (!_nodeExists(src.value)) {
      throw NotFoundException(
          'AddEdge src vid ${src.value} does not exist');
    }
    if (!_nodeExists(dst.value)) {
      throw NotFoundException(
          'AddEdge dst vid ${dst.value} does not exist');
    }
    overlay.recordAddEdge(
      AddedEdge(
        logicalId: logicalId,
        src: src.value,
        dst: dst.value,
        typeId: typeId,
      ),
      eid.value,
    );
    for (final e in props.entries) {
      _writeEdgeProp(eid.value, e.key, e.value);
    }
  }

  /// Applies a `DelEdge` WAL op. Resolves the edge's endpoints (CSR
  /// base via [baseCsrEidToSrc] / [baseCsrEidToDst], or the overlay's
  /// [DeltaOverlay.addedEdges]) and records tombstones on both
  /// directions.
  void applyDelEdge(Eid eid) {
    if (overlay.deletedEdges.contains(eid.value)) return; // idempotent
    final added = overlay.addedEdges[eid.value];
    if (added != null) {
      overlay.recordDelEdge(eid.value, src: added.src, dst: added.dst);
      return;
    }
    if (eid.value >= csr.edgeCount) {
      throw NotFoundException('DelEdge on unknown eid ${eid.value}');
    }
    final src = baseCsrEidToSrc[eid.value];
    final dst = baseCsrEidToDst[eid.value];
    overlay.recordDelEdge(eid.value, src: src, dst: dst);
  }

  /// Applies a `SetEdgeProp` WAL op.
  void applySetEdgeProp(Eid eid, int keyId, PropValue value) {
    _writeEdgeProp(eid.value, keyId, value);
  }

  /// Applies a `DelEdgeProp` WAL op.
  void applyDelEdgeProp(Eid eid, int keyId) {
    edgeProps.remove(eid.value, keyId);
  }

  void _writeNodeProp(int vid, int keyId, PropValue value) =>
      _writeProp(nodeProps, vid, keyId, value);

  void _writeEdgeProp(int eid, int keyId, PropValue value) =>
      _writeProp(edgeProps, eid, keyId, value);

  void _writeProp(PropertyStore store, int id, int keyId, PropValue value) {
    switch (value) {
      case PropInt(:final value):
        store.setInt(id, keyId, value);
      case PropDouble(:final value):
        store.setDouble(id, keyId, value);
      case PropBool(:final value):
        store.setBool(id, keyId, value);
      case PropString(:final value):
        store.setString(id, keyId, value);
      case PropNull():
        store.setNull(id, keyId);
      case PropList():
      case PropMap():
        throw ConstraintViolation(
            'PropList / PropMap cannot be stored in a typed column '
            '. Decompose at the boundary.');
    }
  }

  // ----- Overlay-aware reads --------------------

  /// True if [vid] is a live node (not tombstoned, and either in the
  /// CSR base or in the overlay's added-nodes map).
  bool isNodeVisible(Vid vid) => _nodeExists(vid.value);

  bool _nodeExists(int v) {
    if (overlay.deletedNodes.contains(v)) return false;
    if (v < csr.nodeCount) return true;
    return overlay.addedNodes.containsKey(v);
  }

  /// True iff [vid] effectively carries [labelId] (CSR base + overlay
  /// overrides + overlay-added nodes). Allocation-free on the CSR
  /// path; O(k) on overlay-resident sets where k is per-vid label
  /// count (typically 1–4).
  bool hasLabelEffective(Vid vid, int labelId) {
    final override = overlay.labelOverride[vid.value];
    if (override != null) return override.contains(labelId);
    final added = overlay.addedNodes[vid.value];
    if (added != null) {
      // AddedNode.labelIds is sorted ascending — small list, linear
      // scan is faster than binary search for k ≤ ~10.
      for (final id in added.labelIds) {
        if (id == labelId) return true;
      }
      return false;
    }
    return csr.hasLabel(vid.value, labelId);
  }

  /// Effective label-id set for [vid]. Overlay-aware. Returns a view
  /// where possible (zero-copy off the CSR); returns the live overlay
  /// set or list for overlay-resident entries.
  Iterable<int> effectiveLabelsOf(Vid vid) {
    final override = overlay.labelOverride[vid.value];
    if (override != null) return override;
    final added = overlay.addedNodes[vid.value];
    if (added != null) return added.labelIds;
    return csr.labelsOf(vid.value);
  }

  /// Iterates the live outgoing edges of [vid] — CSR slice (filtered
  /// against the overlay's removed set) followed by overlay-added
  /// edges. Allocation-free.
  void forEachOutEdge(
    Vid vid,
    void Function(Eid eid, Vid dst, int edgeType) visit,
  ) {
    if (!_nodeExists(vid.value)) return;
    final delta = overlay.outDelta[vid.value];
    final removed = delta?.removed;
    if (vid.value < _csr.nodeCount) {
      final end = _csr.rowPtrOut[vid.value + 1];
      for (var i = _csr.rowPtrOut[vid.value]; i < end; i++) {
        final eid = _csr.edgeIdOut[i];
        if (removed != null && removed.contains(eid)) continue;
        if (overlay.deletedNodes.contains(_csr.colIdxOut[i])) continue;
        visit(Eid(eid), Vid(_csr.colIdxOut[i]), _csr.edgeTypeOut[i]);
      }
    }
    if (delta != null) {
      for (final e in delta.added) {
        if (overlay.deletedNodes.contains(e.neighbor)) continue;
        visit(Eid(e.eid), Vid(e.neighbor), e.edgeType);
      }
    }
  }

  /// Iterates the live incoming edges of [vid]. Same shape as
  /// [forEachOutEdge].
  void forEachInEdge(
    Vid vid,
    void Function(Eid eid, Vid src, int edgeType) visit,
  ) {
    if (!_nodeExists(vid.value)) return;
    final delta = overlay.inDelta[vid.value];
    final removed = delta?.removed;
    if (vid.value < _csr.nodeCount) {
      final end = _csr.rowPtrIn[vid.value + 1];
      for (var i = _csr.rowPtrIn[vid.value]; i < end; i++) {
        final eid = _csr.edgeIdIn[i];
        if (removed != null && removed.contains(eid)) continue;
        if (overlay.deletedNodes.contains(_csr.colIdxIn[i])) continue;
        visit(Eid(eid), Vid(_csr.colIdxIn[i]), _csr.edgeTypeIn[i]);
      }
    }
    if (delta != null) {
      for (final e in delta.added) {
        if (overlay.deletedNodes.contains(e.neighbor)) continue;
        visit(Eid(e.eid), Vid(e.neighbor), e.edgeType);
      }
    }
  }

  /// Total node-slot count including overlay-added nodes —
  /// read-your-writes. Exactly matches the post-merge `csr.nodeCount`
  /// (the same max formula `foldOverlayIntoCsr` uses). Deleted nodes
  /// retain their vid slot here as they do across a merge. Fast path
  /// returns `csr.nodeCount` when no nodes are pending.
  int get effectiveNodeCount {
    if (overlay.addedNodes.isEmpty) return csr.nodeCount;
    var n = csr.nodeCount;
    for (final vid in overlay.addedNodes.keys) {
      if (vid + 1 > n) n = vid + 1;
    }
    return n;
  }

  /// Live edge count with the overlay applied — read-your-writes. Adds
  /// overlay-added edges and subtracts hidden base edges. The per-vid
  /// `removed` sets hold only base-CSR eids (an overlay-added edge that
  /// gets deleted is pulled straight out of `addedEdges`), and
  /// `applyDelNode` cascades incident edges into those sets, so this
  /// matches the post-merge `csr.edgeCount` exactly. Fast path returns
  /// `csr.edgeCount` on a clean overlay.
  int get effectiveEdgeCount {
    if (overlay.isEmpty) return csr.edgeCount;
    var removed = 0;
    for (final delta in overlay.outDelta.values) {
      removed += delta.removed.length;
    }
    return csr.edgeCount - removed + overlay.addedEdges.length;
  }

  /// Out-degree with overlay applied (read-your-writes). O(degree) when
  /// writes are pending; O(1) `csr.outDegree` fast path on a clean overlay.
  int effectiveOutDegree(Vid vid) {
    if (overlay.isEmpty) return csr.outDegree(vid.value);
    var n = 0;
    forEachOutEdge(vid, (_, __, ___) => n++);
    return n;
  }

  /// In-degree with overlay applied (read-your-writes). O(degree) when
  /// writes are pending; O(1) `csr.inDegree` fast path on a clean overlay.
  int effectiveInDegree(Vid vid) {
    if (overlay.isEmpty) return csr.inDegree(vid.value);
    var n = 0;
    forEachInEdge(vid, (_, __, ___) => n++);
    return n;
  }

  // ----- Secondary index registry ------------------------------
  //
  // Default (non-incremental, non-deferred) indexes are built once
  // from the current column state and are read-only thereafter. The
  // deferred + incremental variants (and the worker-isolate rebuild
  // hand-off) sit alongside that baseline.

  final Map<String, SecondaryIndex> _nodeIndexes = {};
  final Map<String, SecondaryIndex> _edgeIndexes = {};

  /// Read-only view of the registered node-property indexes.
  Map<String, SecondaryIndex> get nodeIndexes =>
      Map.unmodifiable(_nodeIndexes);

  /// Read-only view of the registered edge-property indexes.
  Map<String, SecondaryIndex> get edgeIndexes =>
      Map.unmodifiable(_edgeIndexes);

  /// Builds a node-property index from the current [nodeProps] column.
  ///
  /// Fires [onSizeEvent] **once** if the freshly-built index size is at
  /// or above [kIndexSizeWarnThreshold] of [csr.sizeBytes] (soft
  /// budget). [onSizeEvent] is optional; pass `null` (default) to
  /// silently build.
  ///
  /// Throws [ConstraintViolation] if an index named [IndexSpec.name]
  /// already exists, or if the column type isn't yet declared.
  SecondaryIndex createNodePropertyIndex(
    IndexSpec spec, {
    IndexSizeListener? onSizeEvent,
  }) =>
      _createIndex(_nodeIndexes, nodeProps, spec, onSizeEvent);

  /// Builds an edge-property index from the current [edgeProps] column.
  /// See [createNodePropertyIndex] for semantics.
  SecondaryIndex createEdgePropertyIndex(
    IndexSpec spec, {
    IndexSizeListener? onSizeEvent,
  }) =>
      _createIndex(_edgeIndexes, edgeProps, spec, onSizeEvent);

  SecondaryIndex _createIndex(
    Map<String, SecondaryIndex> registry,
    PropertyStore store,
    IndexSpec spec,
    IndexSizeListener? onSizeEvent,
  ) {
    if (registry.containsKey(spec.name)) {
      throw ConstraintViolation('index "${spec.name}" already exists');
    }
    final colType = store.columnType(spec.keyId);
    if (colType == null) {
      throw ConstraintViolation(
          'cannot build index "${spec.name}": no column declared for '
          'keyId ${spec.keyId}');
    }

    final SecondaryIndex idx;
    switch (spec.kind) {
      case EqualityRange(:final hashOverlay):
        switch (colType) {
          case ColumnType.int_:
            idx = IntEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.double_:
            idx = DoubleEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.stringId:
            idx = StringIdEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.string:
            idx = StringEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.bool_:
            idx = BoolEqualityRangeIndex.build(
              spec: spec,
              store: store,
            );
        }
    }

    registry[spec.name] = idx;

    if (onSizeEvent != null) {
      final csrBytes = csr.sizeBytes;
      final ratio = csrBytes == 0 ? 0.0 : idx.sizeBytes / csrBytes;
      if (ratio >= kIndexSizeWarnThreshold) {
        onSizeEvent(IndexSizeEvent(
          spec: spec,
          indexBytes: idx.sizeBytes,
          csrBytes: csrBytes,
          ratio: ratio,
          severity: IndexSizeSeverity.warn,
        ));
      }
    }
    return idx;
  }

  /// Looks up a registered node-property index by name.
  SecondaryIndex? getNodeIndex(String name) => _nodeIndexes[name];

  /// Looks up a registered edge-property index by name.
  SecondaryIndex? getEdgeIndex(String name) => _edgeIndexes[name];

  /// Removes a node-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropNodeIndex(String name) => _nodeIndexes.remove(name);

  // mutation hooks
  /// Throws [ConstraintViolation] if [value] is already present on a
  /// different vid in any unique node-property index covering [keyId].
  void _enforceUniqueNodeIndex(int vid, int keyId, PropValue value) {
    for (final idx in _nodeIndexes.values) {
      if (idx.spec.keyId != keyId || !idx.isUnique) continue;
      final existing = _findVidInIndex(idx, value);
      if (existing != null && existing != vid) {
        throw ConstraintViolation(
          'unique index "${idx.spec.name}" violated: '
          'value already on vid $existing',
        );
      }
    }
  }

  /// Names of indexes queued for a deferred rebuild — populated by
  /// the mutation hook for any index whose spec has
  /// `EqualityRange.deferred == true`. Drained by
  /// [flushDeferredIndexUpdates].
  final Set<String> _pendingNodeIndexFlush = {};

  /// Updates every node index whose `keyId` matches [keyId]. Strategy
  /// per-index:
  /// - **incremental + non-unique**: O(1) `insert(vid, value)` /
  ///   `removeVid(vid)` directly on the index (currently `int_`
  ///   columns only — other typed columns fall back to rebuild).
  /// - **deferred + non-unique**: queue the rebuild for the next
  ///   `flushDeferredIndexUpdates()`.
  /// - **otherwise (unique or default)**: drop-and-rebuild inline.
  void _maintainNodeIndexes(int vid, int keyId) {
    for (final name in _nodeIndexes.keys.toList()) {
      final idx = _nodeIndexes[name]!;
      if (idx.spec.keyId != keyId) continue;
      final kind = idx.spec.kind;
      if (kind is EqualityRange &&
          kind.incremental &&
          !kind.unique &&
          _tryIncrementalNodeIndex(idx, vid, keyId)) {
        continue;
      }
      if (kind is EqualityRange && kind.deferred && !kind.unique) {
        _pendingNodeIndexFlush.add(name);
      } else {
        final spec = idx.spec;
        _nodeIndexes.remove(name);
        createNodePropertyIndex(spec);
      }
    }
  }

  /// Returns `true` if the index supports incremental mutation for
  /// the column type at [keyId] AND the update was applied;
  /// `false` to fall back to drop-and-rebuild.
  bool _tryIncrementalNodeIndex(
    SecondaryIndex idx,
    int vid,
    int keyId,
  ) {
    final colType = nodeProps.columnType(keyId);
    if (idx is IntEqualityRangeIndex && colType == ColumnType.int_) {
      if (nodeProps.has(vid, keyId)) {
        idx.insert(vid, nodeProps.getInt(vid, keyId));
      } else {
        idx.removeVid(vid);
      }
      return true;
    }
    return false;
  }

  /// Drop-and-rebuild (or incrementally remove) every registered
  /// node index — used on `applyDelNode` where the affected
  /// [deletedVid] spans every column. Incremental int indexes drop
  /// the vid in O(1) without a full rebuild.
  void _maintainAllNodeIndexes({int? deletedVid}) {
    final names = _nodeIndexes.keys.toList();
    for (final name in names) {
      final idx = _nodeIndexes[name];
      if (idx == null) continue;
      final spec = idx.spec;
      final kind = spec.kind;
      if (kind is EqualityRange &&
          kind.incremental &&
          !kind.unique &&
          deletedVid != null &&
          idx is IntEqualityRangeIndex) {
        idx.removeVid(deletedVid);
        continue;
      }
      if (kind is EqualityRange && kind.deferred && !kind.unique) {
        _pendingNodeIndexFlush.add(spec.name);
      } else {
        _nodeIndexes.remove(spec.name);
        createNodePropertyIndex(spec);
      }
    }
  }

  /// Number of deferred index rebuilds currently queued. Tests +
  /// observability use this; v1 doesn't expose a stream.
  int get pendingDeferredIndexUpdates => _pendingNodeIndexFlush.length;

  /// Async drain that uses [indexRebuildCoordinator] when set,
  /// falling back to the synchronous main-isolate rebuild otherwise
  ///. Worker-supported column types route
  /// through `PersistentWorker.send(...)`; unsupported types fall
  /// back per-index to the sync rebuild path so a mixed workload
  /// keeps making progress.
  Future<void> flushDeferredIndexUpdatesAsync() async {
    if (_pendingNodeIndexFlush.isEmpty) return;
    final coord = indexRebuildCoordinator;
    if (coord == null) {
      flushDeferredIndexUpdates();
      return;
    }
    final pending = List<String>.of(_pendingNodeIndexFlush);
    _pendingNodeIndexFlush.clear();
    for (final name in pending) {
      final idx = _nodeIndexes[name];
      if (idx == null) continue;
      final spec = idx.spec;
      final kind = spec.kind;
      if (idx is IntEqualityRangeIndex && kind is EqualityRange) {
        // Snapshot the column on the main isolate, ship to worker.
        final pairs = <(int, int)>[];
        nodeProps.forEachSetInt(
          spec.keyId,
          (vid, value) => pairs.add((vid, value)),
        );
        final snap = snapshotIntColumn(pairs: pairs);
        final rebuilt = await coord.rebuildInt(
          IndexRebuildIntTask.copyAndWrap(
            spec: spec,
            hashOverlay: kind.hashOverlay,
            values: snap.values,
            vids: snap.vids,
          ),
        );
        _nodeIndexes[name] = buildIntIndexFromSorted(
          spec: spec,
          sortedValues: rebuilt.sortedValues,
          sortedVids: rebuilt.sortedVids,
          hashOverlay: kind.hashOverlay,
        );
      } else {
        // Worker doesn't yet support this column type — fall back to
        // a sync main-isolate rebuild.
        _nodeIndexes.remove(name);
        createNodePropertyIndex(spec);
      }
    }
  }

  /// Drains the deferred-update queue. Each
  /// queued index is dropped + rebuilt from the current state.
  /// Multiple pending updates per index coalesce — the rebuild runs
  /// once. Synchronous on the main isolate — see
  /// [flushDeferredIndexUpdatesAsync] for the worker-isolate variant
  /// that offloads the rebuild when [indexRebuildCoordinator] is set.
  void flushDeferredIndexUpdates() {
    if (_pendingNodeIndexFlush.isEmpty) return;
    final pending = List<String>.of(_pendingNodeIndexFlush);
    _pendingNodeIndexFlush.clear();
    for (final name in pending) {
      final idx = _nodeIndexes[name];
      if (idx == null) continue;
      final spec = idx.spec;
      _nodeIndexes.remove(name);
      createNodePropertyIndex(spec);
    }
  }

  // ----- Constraint catalog mutation hooks -------------

  /// Registers a constraint via the catalog. Called by the
  /// applicator on `DeclareConstraint` and by the public
  /// `GraphDb.declareConstraint`. **Validates existing data** —
  /// throws [ConstraintViolation] if any current vid breaks the
  /// proposed constraint.
  void applyDeclareConstraint({
    required String name,
    required int labelId,
    required int keyId,
    required ConstraintKind kind,
  }) {
    final ConstraintSpec spec = switch (kind) {
      ConstraintKind.unique => UniqueConstraint(
          name: name, labelId: labelId, keyId: keyId,
        ),
      ConstraintKind.existence => ExistenceConstraint(
          name: name, labelId: labelId, keyId: keyId,
        ),
    };
    _validateConstraintAgainstExistingData(spec);
    constraints.declare(spec);
    // Auto-create an underlying unique index so per-mutation
    // enforcement comes for free via the unique-index path.
    // v1 limitation: the index is global across all labels (doesn't
    // honour [spec.labelId]) — a property uniqueness scoped to one
    // label is enforced only at declare-time validation, not on
    // post-declare mutations that touch other labels. Polish item.
    if (spec is UniqueConstraint) {
      final indexName = '__uq_${spec.name}';
      // Skip if the column hasn't been declared yet — the constraint
      // still registers and re-checks happen on future mutations.
      // (Polish: hook column-declare to lazily create the index.)
      if (getNodeIndex(indexName) == null &&
          nodeProps.columnType(spec.keyId) != null) {
        createNodePropertyIndex(IndexSpec(
          name: indexName,
          keyId: spec.keyId,
          kind: const EqualityRange(unique: true, incremental: true),
        ));
      }
    }
  }

  /// Drops a constraint by name. Idempotent.
  void applyDropConstraint(String name) {
    constraints.drop(name);
  }

  void _validateConstraintAgainstExistingData(ConstraintSpec spec) {
    if (spec is UniqueConstraint) {
      final seen = <Object, int>{};
      _forEachVidWithLabel(spec.labelId, (vid) {
        if (!nodeProps.has(vid, spec.keyId)) return;
        final value = nodeProps.getBoxed(vid, spec.keyId);
        if (value == null || value is PropNull) return;
        final raw = _propRaw(value);
        final prior = seen[raw];
        if (prior != null) {
          throw ConstraintViolation(
            'unique constraint "${spec.name}" violated by existing data: '
            'value already on vid $prior',
          );
        }
        seen[raw] = vid;
      });
    } else if (spec is ExistenceConstraint) {
      _forEachVidWithLabel(spec.labelId, (vid) {
        if (!nodeProps.has(vid, spec.keyId)) {
          throw ConstraintViolation(
            'existence constraint "${spec.name}" violated by existing data: '
            'vid $vid has no value for key ${spec.keyId}',
          );
        }
      });
    }
  }

  void _forEachVidWithLabel(int labelId, void Function(int) visit) {
    // 1. Walk every base-CSR vid carrying [labelId] — but skip if a
    //    label-override has rewritten the set and that set no longer
    //    contains the label.
    final base = _csr.labelIndex[labelId];
    if (base != null) {
      for (final v in base) {
        if (overlay.deletedNodes.contains(v)) continue;
        final ov = overlay.labelOverride[v];
        if (ov != null && !ov.contains(labelId)) continue;
        visit(v);
      }
    }
    // 2. Overlay-added nodes whose set contains [labelId].
    for (final entry in overlay.addedNodes.entries) {
      if (overlay.deletedNodes.contains(entry.key)) continue;
      if (entry.value.labelIds.contains(labelId)) {
        visit(entry.key);
      }
    }
    // 3. Pre-existing CSR vids that *gained* [labelId] via a
    //    label-override (i.e. the base CSR didn't carry it).
    for (final entry in overlay.labelOverride.entries) {
      if (!entry.value.contains(labelId)) continue;
      if (overlay.deletedNodes.contains(entry.key)) continue;
      if (entry.key < _csr.nodeCount &&
          _csr.hasLabel(entry.key, labelId)) {
        // Already yielded by step 1.
        continue;
      }
      visit(entry.key);
    }
  }

  Object _propRaw(PropValue v) => switch (v) {
        PropInt(:final value) => value,
        PropDouble(:final value) => value,
        PropBool(:final value) => value,
        PropString(:final value) => value,
        PropNull() => '__null__',
        PropList() || PropMap() => v.toString(),
      };

  /// Returns the first vid carrying [value] in [idx], or `null` if
  /// the value isn't indexed. O(log n) for sorted-array indexes
  /// (binary search); skips the hash overlay for simplicity.
  int? _findVidInIndex(SecondaryIndex idx, PropValue value) {
    if (idx is IntEqualityRangeIndex && value is PropInt) {
      final lo = idx.lowerBound(value.value);
      final hi = idx.upperBound(value.value);
      return lo < hi ? idx.vidAt(lo) : null;
    }
    if (idx is DoubleEqualityRangeIndex && value is PropDouble) {
      final lo = idx.lowerBound(value.value);
      final hi = idx.upperBound(value.value);
      return lo < hi ? idx.vidAt(lo) : null;
    }
    if (idx is StringIdEqualityRangeIndex && value is PropInt) {
      final lo = idx.lowerBound(value.value);
      final hi = idx.upperBound(value.value);
      return lo < hi ? idx.vidAt(lo) : null;
    }
    if (idx is StringEqualityRangeIndex && value is PropString) {
      final lo = idx.lowerBound(value.value);
      final hi = idx.upperBound(value.value);
      return lo < hi ? idx.vidAt(lo) : null;
    }
    if (idx is BoolEqualityRangeIndex && value is PropBool) {
      final (lo, hi) = idx.equalRange(value.value);
      return lo < hi ? idx.vidAt(lo) : null;
    }
    return null;
  }

  /// Removes an edge-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropEdgeIndex(String name) => _edgeIndexes.remove(name);
}
