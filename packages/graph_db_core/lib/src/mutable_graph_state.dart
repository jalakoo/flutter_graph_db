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

/// The composed in-memory state the engine reads from (plan §2.1).
///
/// Phase 1: built once from a fixture via [MutableGraphState.fromFixture]
/// and read-only thereafter. Phase 2 adds the mutation path — the
/// `apply(WalOp)` applicator, the delta overlay, and the WAL.
///
/// Read primitives live here as thin wrappers over the underlying [Csr]
/// + [PropertyStore]. The `outRangeStart` / `outRangeEnd` pair is the
/// **primitive range read API** that Spike A picked as the v1 read
/// shape (plan §5, §7.1) — allocation-free, the simplest, and the
/// fastest on AOT.
class MutableGraphState {
  final StringInterner strings;
  Csr _csr;
  final PropertyStore nodeProps;
  final PropertyStore edgeProps;
  final DeltaOverlay overlay;

  /// Current CSR. Re-bound by [installMergedCsr] when the overlay
  /// folds into a fresh CSR (plan §3.4 / §14 Phase 2E). Callers that
  /// cache the reference across an `await` should re-read after the
  /// await — same shape as `state.csr` outside a transaction.
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

  /// Soft merge trigger override (plan §14 Phase 2E). When `null`,
  /// the formula `max(10_000, 5 % of csr.edgeCount)` is used per
  /// §3.4. Tests set a small value to force a merge after a handful
  /// of mutations.
  int? mergeThreshold;

  /// Optional worker-isolate merge coordinator (plan §2.3 / §14
  /// Phase 2 polish). When set, [maybeMergeOverlayAsync] hands the
  /// fold off to the worker and the main-isolate stall is only the
  /// copy + install cost. When `null`, the same call falls back to
  /// the synchronous [mergeNow] path. Set via
  /// `MergeCoordinator.spawn()` and assign before any merge would
  /// fire.
  MergeCoordinator? mergeCoordinator;

  /// Optional worker-isolate index-rebuild coordinator (plan §14
  /// Phase 5B+). When set, [flushDeferredIndexUpdatesAsync] hands
  /// rebuilds off to the worker (supported column types only — int_
  /// today; other types fall back to main-isolate rebuild). When
  /// `null`, the same async call runs the rebuild inline.
  IndexRebuildCoordinator? indexRebuildCoordinator;

  /// Constraint catalog (plan §4 / §14 Phase 6C). Rebuilt from the
  /// WAL on recovery via the `DeclareConstraint` / `DropConstraint`
  /// ops. Application code reads this to introspect active
  /// constraints; mutations enforce against it automatically.
  final ConstraintCatalog constraints = ConstraintCatalog();

  int _nextVid;
  int _nextEid;

  /// LSN assigned to the next [SequencedWalOp]. Phase 2B uses a simple
  /// counter; Phase 2C replaces this with the WAL byte offset.
  int _nextLsn;

  /// Txn id assigned to the next transaction. Phase 2B counter; in
  /// later phases the WAL header carries the highest txn id for
  /// recovery to resume from.
  int _nextTxnId;

  /// The currently-active txn id, or `null` if no txn is in flight.
  /// Phase 2B single-writer (plan §2.3) — a second `runTransaction`
  /// while [activeTxnId] is non-null throws.
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
    final out = Uint32List(csr.edgeCount);
    for (var v = 0; v < csr.nodeCount; v++) {
      final end = csr.rowPtrOut[v + 1];
      for (var i = csr.rowPtrOut[v]; i < end; i++) {
        out[csr.edgeIdOut[i]] = v;
      }
    }
    return out;
  }

  static Uint32List _buildEidToDst(Csr csr) {
    final out = Uint32List(csr.edgeCount);
    for (var v = 0; v < csr.nodeCount; v++) {
      final end = csr.rowPtrOut[v + 1];
      for (var i = csr.rowPtrOut[v]; i < end; i++) {
        out[csr.edgeIdOut[i]] = csr.colIdxOut[i];
      }
    }
    return out;
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

  // ----- Merge trigger (plan §3.4, §14 Phase 2E) ---------------------------

  /// Total overlay mutation count. Threshold metric for the merge
  /// trigger (plan §14: `max(10_000, 5 %)`).
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
  /// [installMergedCsr]. **Synchronous** main-isolate fold for v1 —
  /// the worker-isolate hand-off (Spike B design) is a Phase 2 polish
  /// follow-up; the merge-stall <1 ms acceptance metric requires it
  /// for graphs much larger than the 100 k bench fixture (see
  /// `4_PLAN.md` Phase 2 sub-table).
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
  /// off-main). Plan §14 acceptance metric: `< 1 ms` p99 stall.
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

  // ----- Topology reads — primitive range API (plan §5, Spike A) -----------
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

  static final Uint32List _emptyU32 = Uint32List(0);

  // ----- Property reads — raw primitives (plan §3.2) -----------------------

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

  // ----- Allocators (plan §3.6 — vid never reused) -------------------------

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

  // ----- Mutation appliers (plan §2.1 — the single mutation path) ----------
  //
  // These are the methods the applicator (`apply()`) routes WalOp arms
  // to. Transaction builders call [allocVid] / [allocEid] first to
  // assign ids, then construct the WalOp, then feed it through `apply`.
  //
  // Phase 2A: writes land in the [DeltaOverlay] (or directly in
  // [PropertyStore] for property ops, since the property store has no
  // overlay layer — values are mutable in place). Phase 2C wires WAL
  // persistence around these calls; Phase 2E wires the worker-isolate
  // merge that folds the overlay back into the CSR base.

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
          '(vids are never reused — plan §3.6)');
    }
    if (vid.value >= _nextVid) {
      _nextVid = vid.value + 1;
      _ensureNodeCapacity(vid.value);
    }
    if (labelIds.isEmpty) {
      throw ConstraintViolation(
          'AddNode requires at least one label id (v1 single-label '
          'storage — multi-label is Phase 1.1)');
    }
    if (labelIds.length > 1) {
      throw ConstraintViolation(
          'AddNode given ${labelIds.length} labels; v1 is single-label '
          '(plan §6.4 multi-label is Phase 1.1)');
    }
    // Existence-constraint pre-check (plan §14 Phase 6C) — fail
    // before any property writes so partial state isn't left behind.
    constraints.enforceExistenceOnAddNode(
      labelId: labelIds.first,
      props: props,
    );
    overlay.recordAddNode(
      vid.value,
      AddedNode(logicalId: logicalId, labelIds: List.of(labelIds)),
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

  /// Applies a `SetNodeLabels` WAL op under v1's single-label
  /// constraint. Accepts `(added: [newLabel], removed: [oldLabel])`
  /// (a relabel) or `(added: [], removed: [oldLabel])` and `(added:
  /// [newLabel], removed: [])` are also accepted as no-replace /
  /// no-prior single-label transitions.
  void applySetNodeLabels(
    Vid vid, {
    required List<int> added,
    required List<int> removed,
  }) {
    if (added.length > 1 || removed.length > 1) {
      throw ConstraintViolation(
          'SetNodeLabels v1 single-label only (added=${added.length}, '
          'removed=${removed.length}); multi-label is Phase 1.1');
    }
    if (!_nodeExists(vid.value)) {
      throw NotFoundException('SetNodeLabels on absent vid ${vid.value}');
    }
    if (added.isEmpty) return; // removed-only is a no-op under single-label
    final newLabel = added.first;
    // Overlay-added node? mutate AddedNode.labelIds in place.
    final addedNode = overlay.addedNodes[vid.value];
    if (addedNode != null) {
      addedNode.labelIds
        ..clear()
        ..add(newLabel);
    } else {
      overlay.recordSetNodeLabel(vid.value, newLabel);
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
      labelOf: (v) => effectiveLabelOf(Vid(v)),
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
            '(plan §3.2). Decompose at the boundary.');
    }
  }

  // ----- Overlay-aware reads (plan §2 — base + overlay) --------------------

  /// True if [vid] is a live node (not tombstoned, and either in the
  /// CSR base or in the overlay's added-nodes map).
  bool isNodeVisible(Vid vid) => _nodeExists(vid.value);

  bool _nodeExists(int v) {
    if (overlay.deletedNodes.contains(v)) return false;
    if (v < csr.nodeCount) return true;
    return overlay.addedNodes.containsKey(v);
  }

  /// The effective single label for [vid] — overlay override first,
  /// then [AddedNode.labelIds.first], then `csr.labelOf[vid]`.
  int effectiveLabelOf(Vid vid) {
    final override = overlay.labelOverride[vid.value];
    if (override != null) return override;
    final added = overlay.addedNodes[vid.value];
    if (added != null) return added.labelIds.first;
    return csr.labelOf[vid.value];
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

  /// Out-degree with overlay applied. O(degree).
  int effectiveOutDegree(Vid vid) {
    var n = 0;
    forEachOutEdge(vid, (_, __, ___) => n++);
    return n;
  }

  /// In-degree with overlay applied. O(degree).
  int effectiveInDegree(Vid vid) {
    var n = 0;
    forEachInEdge(vid, (_, __, ___) => n++);
    return n;
  }

  // ----- Secondary index registry (plan §3.3) ------------------------------
  //
  // Built once from the current column state — Phase 1 is read-only.
  // Phase 5 will revisit incremental update + the deferred build via the
  // §2.3 worker hand-off.

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
  /// or above [kIndexSizeWarnThreshold] of [csr.sizeBytes] (plan §3.3
  /// soft budget). [onSizeEvent] is optional; pass `null` (default) to
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

  // ----- Phase 5 mutation hooks (plan §14 Phase 5A) -----------------------

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
  /// [flushDeferredIndexUpdates] (plan §14 Phase 5B).
  final Set<String> _pendingNodeIndexFlush = {};

  /// Updates every node index whose `keyId` matches [keyId] (plan
  /// §14 Phase 5). Strategy per-index:
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
  /// (plan §14 Phase 5B+). Worker-supported column types route
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

  /// Drains the deferred-update queue (plan §14 Phase 5B). Each
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

  // ----- Constraint catalog mutation hooks (plan §14 Phase 6C) -------------

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
    // enforcement comes for free via the Phase 5 unique path.
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
    final base = _csr.labelIndex[labelId];
    if (base != null) {
      for (final v in base) {
        if (overlay.deletedNodes.contains(v)) continue;
        final ov = overlay.labelOverride[v];
        if (ov != null && ov != labelId) continue;
        visit(v);
      }
    }
    for (final entry in overlay.addedNodes.entries) {
      if (overlay.deletedNodes.contains(entry.key)) continue;
      if (entry.value.labelIds.isNotEmpty &&
          entry.value.labelIds.first == labelId) {
        visit(entry.key);
      }
    }
    for (final entry in overlay.labelOverride.entries) {
      if (entry.value != labelId) continue;
      if (overlay.deletedNodes.contains(entry.key)) continue;
      if (entry.key < _csr.nodeCount &&
          _csr.labelOf[entry.key] == labelId) {
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
