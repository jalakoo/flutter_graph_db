/// Owns the secondary-index maps **and** the enforce→write→maintain
/// sequence that keeps them correct after every mutation.
///
/// Extracted from `MutableGraphState` (plan A2): the invariant "after any
/// mutation, every affected index is correct" used to be open-coded as a
/// dance repeated at each mutation site, where a wrong call order or a
/// missed step would silently staleness an index. Concentrating the
/// sequence here makes the mutation sites declarative — they call
/// [beforeNodeWrite] / [afterNodeWrite] / [onNodeDeleted] and the registry
/// owns *how*.
///
/// **Narrow deps — no back-reference to `MutableGraphState`.** The
/// registry reaches the rest of the engine through exactly four handles:
/// the two property stores, a getter for the (optionally set) rebuild
/// coordinator, and a getter for the CSR's byte size (the sole input to
/// the size-budget ratio). That makes it unit-testable against a bare
/// [PropertyStore] — see `test/index_registry_test.dart`.
library;

import '../exceptions.dart';
import '../prop_value.dart';
import '../property_store.dart';
import 'index_size_event.dart';
import 'index_spec.dart';
import 'index_worker.dart';
import 'secondary_index.dart';

/// Internal-only collaborator of `MutableGraphState`. Not exported from
/// the package barrel; sibling-package and test access go through the
/// `src/` path.
class IndexRegistry {
  final PropertyStore _nodeProps;
  final PropertyStore _edgeProps;

  /// Resolves the active index-rebuild coordinator, or `null` for the
  /// synchronous main-isolate rebuild path. A getter (not a value)
  /// because the host sets the coordinator *after* the registry is
  /// constructed (e.g. `state.indexRebuildCoordinator = …`).
  final IndexRebuildCoordinator? Function() _coordinator;

  /// Current CSR byte size — denominator of the size-budget ratio. A
  /// getter because the CSR is re-bound on every overlay merge.
  final int Function() _csrSizeBytes;

  /// Effective-label test, used only to scope unique enforcement to a
  /// constraint's label (see [IndexSpec.labelScope]). Injected as a
  /// closure so the registry keeps its narrow deps — it still holds no
  /// back-reference to `MutableGraphState`. Defaults to "carries every
  /// label", which makes an unscoped index behave exactly as before.
  final bool Function(int vid, int labelId) _hasLabel;

  IndexRegistry({
    required PropertyStore nodeProps,
    required PropertyStore edgeProps,
    required IndexRebuildCoordinator? Function() coordinator,
    required int Function() csrSizeBytes,
    bool Function(int vid, int labelId)? hasLabel,
  })  : _nodeProps = nodeProps,
        _edgeProps = edgeProps,
        _coordinator = coordinator,
        _csrSizeBytes = csrSizeBytes,
        _hasLabel = hasLabel ?? _alwaysHasLabel;

  static bool _alwaysHasLabel(int vid, int labelId) => true;

  final Map<String, SecondaryIndex> _nodeIndexes = {};
  final Map<String, SecondaryIndex> _edgeIndexes = {};

  /// Read-only view of the registered node-property indexes.
  Map<String, SecondaryIndex> get nodeIndexes => Map.unmodifiable(_nodeIndexes);

  /// Read-only view of the registered edge-property indexes.
  Map<String, SecondaryIndex> get edgeIndexes => Map.unmodifiable(_edgeIndexes);

  /// Builds a node-property index from the current node column.
  ///
  /// Fires [onSizeEvent] **once** if the freshly-built index size is at
  /// or above [kIndexSizeWarnThreshold] of the CSR size (soft budget).
  /// [onSizeEvent] is optional; pass `null` (default) to silently build.
  ///
  /// Throws [ConstraintViolation] if an index named [IndexSpec.name]
  /// already exists, or if the column type isn't yet declared.
  SecondaryIndex createNodeIndex(
    IndexSpec spec, {
    IndexSizeListener? onSizeEvent,
  }) =>
      _createIndex(_nodeIndexes, _nodeProps, spec, onSizeEvent);

  /// Builds an edge-property index from the current edge column. See
  /// [createNodeIndex] for semantics.
  SecondaryIndex createEdgeIndex(
    IndexSpec spec, {
    IndexSizeListener? onSizeEvent,
  }) =>
      _createIndex(_edgeIndexes, _edgeProps, spec, onSizeEvent);

  SecondaryIndex _createIndex(
    Map<String, SecondaryIndex> registry,
    PropertyStore store,
    IndexSpec spec,
    IndexSizeListener? onSizeEvent,
  ) {
    if (registry.containsKey(spec.name)) {
      throw ConstraintViolation('index "${spec.name}" already exists');
    }
    // Unique + incremental is rejected rather than silently downgraded.
    // `_afterWrite` already refuses the incremental path for unique
    // indexes (it drop-and-rebuilds instead), which is what makes
    // `_findConflictInIndex` sound in reading only the sorted arrays —
    // an incrementally-inserted value can live in the hash overlay
    // alone. Accepting the flag would make uniqueness look enforced
    // while it quietly wasn't.
    final kind = spec.kind;
    if (kind is EqualityRange && kind.unique && kind.incremental) {
      throw ConstraintViolation(
        'index "${spec.name}": EqualityRange(unique: true, incremental: true) '
        'is not supported — a unique index is always rebuilt so enforcement '
        'can read the sorted arrays. Drop `incremental`.',
      );
    }
    // A declared valueType lets the index be built before any data
    // exists: create the (empty) column of that type so the index has a
    // concrete implementation to bind to and later writes are type-locked
    // to it. `createColumn` is a no-op if the column already matches and
    // throws if it conflicts — that's the type-mismatch guard.
    if (spec.valueType != null) {
      store.createColumn(spec.keyId, spec.valueType!);
    }
    final colType = store.columnType(spec.keyId);
    if (colType == null) {
      throw ConstraintViolation(
          'cannot build index "${spec.name}": no column exists for keyId '
          '${spec.keyId}. Write the property first, or set '
          'IndexSpec(valueType: …) to index ahead of any writes.');
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
      final csrBytes = _csrSizeBytes();
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
  SecondaryIndex? getNode(String name) => _nodeIndexes[name];

  /// Looks up a registered edge-property index by name.
  SecondaryIndex? getEdge(String name) => _edgeIndexes[name];

  /// Removes a node-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropNode(String name) => _nodeIndexes.remove(name);

  /// Removes an edge-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropEdge(String name) => _edgeIndexes.remove(name);

  // ----- Mutation sequence ----------------------------------
  //
  // The hooks below are the declarative surface the mutation sites call.
  // `before*Write` enforces uniqueness *before* the columnar write lands
  // (so a rejected write leaves no partial state); `after*Write`
  // re-derives every affected index *after* the write; `on*Deleted`
  // drops the id from every index.
  //
  // **Node and edge are the same sequence over a different store.** They
  // are written once here and parameterised, because the edge half used
  // to be missing entirely: `createEdgeIndex` registered an index and
  // nothing ever maintained it, so `setEdgeProp` / `delEdge` left it
  // silently stale — a lookup for the new value found nothing and a
  // lookup for the old value returned a dead hit.

  /// Throws [ConstraintViolation] if [value] is already present on a
  /// different vid in any unique node-property index covering [keyId].
  /// Call this *before* the columnar write so a rejection leaves no
  /// partial state behind.
  void beforeNodeWrite(int vid, int keyId, PropValue value) =>
      _beforeWrite(_nodeIndexes, vid, keyId, value);

  /// Edge analogue of [beforeNodeWrite].
  void beforeEdgeWrite(int eid, int keyId, PropValue value) =>
      _beforeWrite(_edgeIndexes, eid, keyId, value);

  void _beforeWrite(
    Map<String, SecondaryIndex> registry,
    int id,
    int keyId,
    PropValue value,
  ) {
    for (final idx in registry.values) {
      if (idx.spec.keyId != keyId || !idx.isUnique) continue;
      final existing = _findConflictInIndex(idx, value, id);
      if (existing != null) {
        throw ConstraintViolation(
          'unique index "${idx.spec.name}" violated: '
          'value already on vid $existing',
        );
      }
    }
  }

  /// Re-checks label-scoped unique enforcement for [vid] on the
  /// assumption that it is about to gain [gainedLabels].
  ///
  /// Gaining a label can pull a node into a unique constraint's scope for
  /// a value it already holds, so `SetNodeLabels` has to check the same
  /// thing a property write does. Called *before* the new label set is
  /// persisted, which is why the gained labels are passed explicitly
  /// rather than read back through [_hasLabel].
  void beforeLabelGain(int vid, Set<int> gainedLabels) {
    if (gainedLabels.isEmpty) return;
    for (final idx in _nodeIndexes.values) {
      final scope = idx.spec.labelScope;
      if (!idx.isUnique || scope == null) continue;
      if (!gainedLabels.contains(scope)) continue;
      final keyId = idx.spec.keyId;
      if (!_nodeProps.has(vid, keyId)) continue;
      final value = _nodeProps.getBoxed(vid, keyId);
      if (value == null || value is PropNull) continue;
      final (lo, hi) = _equalRange(idx, value);
      for (var i = lo; i < hi; i++) {
        final other = idx.vidAt(i);
        if (other == vid || !_hasLabel(other, scope)) continue;
        throw ConstraintViolation(
          'unique index "${idx.spec.name}" violated: cannot add label $scope '
          'to vid $vid — its value for key $keyId is already on vid $other',
        );
      }
    }
  }

  /// Names of node indexes queued for a deferred rebuild — populated by
  /// [afterNodeWrite] / [onNodeDeleted] for any index whose spec has
  /// `EqualityRange.deferred == true`. Drained by
  /// [flushDeferredIndexUpdates].
  final Set<String> _pendingNodeIndexFlush = {};

  /// Edge counterpart of [_pendingNodeIndexFlush].
  final Set<String> _pendingEdgeIndexFlush = {};

  /// Updates every node index whose `keyId` matches [keyId], *after* the
  /// columnar write has landed. Strategy per-index:
  /// - **incremental + non-unique**: O(1) `insert(vid, value)` /
  ///   `removeVid(vid)` directly on the index (currently `int_`
  ///   columns only — other typed columns fall back to rebuild).
  /// - **deferred + non-unique**: queue the rebuild for the next
  ///   [flushDeferredIndexUpdates].
  /// - **otherwise (unique or default)**: drop-and-rebuild inline.
  void afterNodeWrite(int vid, int keyId) => _afterWrite(
        _nodeIndexes,
        _nodeProps,
        _pendingNodeIndexFlush,
        createNodeIndex,
        vid,
        keyId,
      );

  /// Edge analogue of [afterNodeWrite].
  void afterEdgeWrite(int eid, int keyId) => _afterWrite(
        _edgeIndexes,
        _edgeProps,
        _pendingEdgeIndexFlush,
        createEdgeIndex,
        eid,
        keyId,
      );

  void _afterWrite(
    Map<String, SecondaryIndex> registry,
    PropertyStore store,
    Set<String> pendingFlush,
    SecondaryIndex Function(IndexSpec) rebuild,
    int id,
    int keyId,
  ) {
    for (final name in registry.keys.toList()) {
      final idx = registry[name];
      if (idx == null || idx.spec.keyId != keyId) continue;
      final kind = idx.spec.kind;
      if (kind is EqualityRange &&
          kind.incremental &&
          !kind.unique &&
          _tryIncremental(idx, store, id, keyId)) {
        continue;
      }
      if (kind is EqualityRange && kind.deferred && !kind.unique) {
        pendingFlush.add(name);
      } else {
        final spec = idx.spec;
        registry.remove(name);
        rebuild(spec);
      }
    }
  }

  /// Returns `true` if the index supports incremental mutation for
  /// the column type at [keyId] AND the update was applied;
  /// `false` to fall back to drop-and-rebuild.
  bool _tryIncremental(
    SecondaryIndex idx,
    PropertyStore store,
    int id,
    int keyId,
  ) {
    final colType = store.columnType(keyId);
    if (idx is IntEqualityRangeIndex && colType == ColumnType.int_) {
      if (store.has(id, keyId)) {
        idx.insert(id, store.getInt(id, keyId));
      } else {
        idx.removeVid(id);
      }
      return true;
    }
    return false;
  }

  /// Drop-and-rebuild (or incrementally remove) every registered node
  /// index — used when [vid] is deleted and its absence spans every
  /// column. Incremental int indexes drop the vid in O(1) without a
  /// full rebuild.
  ///
  /// Prefer [beginBatch] / [endBatch] around a multi-delete: without it
  /// each deleted id drop-and-rebuilds every non-incremental index, so
  /// deleting k ids over an n-row index costs O(k·n).
  void onNodeDeleted(int vid) => _onDeleted(
        _nodeIndexes,
        _pendingNodeIndexFlush,
        createNodeIndex,
        vid,
      );

  /// Edge analogue of [onNodeDeleted] — call when an edge is removed and
  /// its property values go with it.
  void onEdgeDeleted(int eid) => _onDeleted(
        _edgeIndexes,
        _pendingEdgeIndexFlush,
        createEdgeIndex,
        eid,
      );

  void _onDeleted(
    Map<String, SecondaryIndex> registry,
    Set<String> pendingFlush,
    SecondaryIndex Function(IndexSpec) rebuild,
    int id,
  ) {
    for (final name in registry.keys.toList()) {
      final idx = registry[name];
      if (idx == null) continue;
      final spec = idx.spec;
      final kind = spec.kind;
      if (kind is EqualityRange &&
          kind.incremental &&
          !kind.unique &&
          idx is IntEqualityRangeIndex) {
        idx.removeVid(id);
        continue;
      }
      // Inside a batch, coalesce: queue the rebuild and run it once at
      // `endBatch` instead of per-id.
      if (_batchDepth > 0 || (kind is EqualityRange && kind.deferred && !kind.unique)) {
        pendingFlush.add(spec.name);
      } else {
        registry.remove(spec.name);
        rebuild(spec);
      }
    }
  }

  // ----- Rebuild batching ---------------------------------------------------

  int _batchDepth = 0;

  /// Coalesces index rebuilds until the matching [endBatch]. The
  /// mutation path opens a batch around a transaction so a cascade
  /// (`delNode` removing a high-degree node's edges, or a bulk delete)
  /// pays one rebuild per index rather than one per id.
  ///
  /// Re-entrant: nested calls increment a depth counter and only the
  /// outermost [endBatch] flushes.
  void beginBatch() => _batchDepth++;

  /// Closes a [beginBatch] and, at depth 0, drains every rebuild the
  /// batch coalesced. Safe to call when no batch is open.
  void endBatch() {
    if (_batchDepth == 0) return;
    _batchDepth--;
    if (_batchDepth == 0) flushDeferredIndexUpdates();
  }

  /// Number of deferred index rebuilds currently queued, across node and
  /// edge indexes. Tests + observability use this; v1 doesn't expose a
  /// stream.
  int get pendingDeferredIndexUpdates =>
      _pendingNodeIndexFlush.length + _pendingEdgeIndexFlush.length;

  /// Async drain that uses the rebuild coordinator when set, falling
  /// back to the synchronous main-isolate rebuild otherwise.
  /// Worker-supported column types route through
  /// `PersistentWorker.send(...)`; unsupported types fall back per-index
  /// to the sync rebuild path so a mixed workload keeps making progress.
  Future<void> flushDeferredIndexUpdatesAsync() async {
    if (pendingDeferredIndexUpdates == 0) return;
    final coord = _coordinator();
    if (coord == null) {
      flushDeferredIndexUpdates();
      return;
    }
    // Edge indexes have no worker path (the rebuild task types are
    // node-column shaped), so drain them on the main isolate first.
    _flushQueue(_pendingEdgeIndexFlush, _edgeIndexes, createEdgeIndex);
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
        _nodeProps.forEachSetInt(
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
        createNodeIndex(spec);
      }
    }
  }

  /// Drains the deferred-update queue. Each queued index is dropped +
  /// rebuilt from the current state. Multiple pending updates per index
  /// coalesce — the rebuild runs once. Synchronous on the main isolate —
  /// see [flushDeferredIndexUpdatesAsync] for the worker-isolate variant
  /// that offloads the rebuild when a coordinator is set.
  void flushDeferredIndexUpdates() {
    _flushQueue(_pendingNodeIndexFlush, _nodeIndexes, createNodeIndex);
    _flushQueue(_pendingEdgeIndexFlush, _edgeIndexes, createEdgeIndex);
  }

  void _flushQueue(
    Set<String> queue,
    Map<String, SecondaryIndex> registry,
    SecondaryIndex Function(IndexSpec) rebuild,
  ) {
    if (queue.isEmpty) return;
    final pending = List<String>.of(queue);
    queue.clear();
    for (final name in pending) {
      final idx = registry[name];
      if (idx == null) continue;
      final spec = idx.spec;
      registry.remove(name);
      rebuild(spec);
    }
  }

  /// Returns an id, other than [selfId], that already carries [value] in
  /// [idx] — or `null` if [value] is unclaimed. O(log n) to locate the
  /// equal range, then linear in the number of ids sharing that value.
  ///
  /// Scans the **whole** equal range rather than returning the first hit:
  /// with a label-scoped unique index the first hit may be out of scope
  /// (see [_labelScopeOf]), and returning it would mask an in-scope
  /// duplicate sitting later in the range.
  ///
  /// Reads only the sorted arrays. That is sound because a unique index
  /// is never incremental (enforced in [_createIndex]), so it is always
  /// freshly rebuilt and its hash overlay never holds an entry the
  /// sorted arrays lack.
  int? _findConflictInIndex(SecondaryIndex idx, PropValue value, int selfId) {
    final (lo, hi) = _equalRange(idx, value);
    if (lo >= hi) return null;
    final scope = _labelScopeOf(idx);
    // An out-of-scope writer can never conflict: the constraint only
    // covers ids carrying the scoped label.
    if (scope != null && !_hasLabel(selfId, scope)) return null;
    for (var i = lo; i < hi; i++) {
      final other = idx.vidAt(i);
      if (other == selfId) continue;
      if (scope != null && !_hasLabel(other, scope)) continue;
      return other;
    }
    return null;
  }

  /// The `[lo, hi)` sorted-array positions holding [value], or an empty
  /// range when the index type and value type don't line up.
  (int, int) _equalRange(SecondaryIndex idx, PropValue value) {
    if (idx is IntEqualityRangeIndex && value is PropInt) {
      return (idx.lowerBound(value.value), idx.upperBound(value.value));
    }
    if (idx is DoubleEqualityRangeIndex && value is PropDouble) {
      return (idx.lowerBound(value.value), idx.upperBound(value.value));
    }
    if (idx is StringIdEqualityRangeIndex && value is PropInt) {
      return (idx.lowerBound(value.value), idx.upperBound(value.value));
    }
    if (idx is StringEqualityRangeIndex && value is PropString) {
      return (idx.lowerBound(value.value), idx.upperBound(value.value));
    }
    if (idx is BoolEqualityRangeIndex && value is PropBool) {
      return idx.equalRange(value.value);
    }
    return (0, 0);
  }

  int? _labelScopeOf(SecondaryIndex idx) => idx.spec.labelScope;
}
