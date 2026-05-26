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

  IndexRegistry({
    required PropertyStore nodeProps,
    required PropertyStore edgeProps,
    required IndexRebuildCoordinator? Function() coordinator,
    required int Function() csrSizeBytes,
  })  : _nodeProps = nodeProps,
        _edgeProps = edgeProps,
        _coordinator = coordinator,
        _csrSizeBytes = csrSizeBytes;

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
  // The three hooks below are the declarative surface the mutation
  // sites call. `beforeNodeWrite` enforces uniqueness *before* the
  // columnar write lands (so a rejected write leaves no partial state);
  // `afterNodeWrite` re-derives every affected index *after* the write;
  // `onNodeDeleted` drops the vid from every index.

  /// Throws [ConstraintViolation] if [value] is already present on a
  /// different vid in any unique node-property index covering [keyId].
  /// Call this *before* the columnar write so a rejection leaves no
  /// partial state behind.
  void beforeNodeWrite(int vid, int keyId, PropValue value) {
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
  /// [afterNodeWrite] / [onNodeDeleted] for any index whose spec has
  /// `EqualityRange.deferred == true`. Drained by
  /// [flushDeferredIndexUpdates].
  final Set<String> _pendingNodeIndexFlush = {};

  /// Updates every node index whose `keyId` matches [keyId], *after* the
  /// columnar write has landed. Strategy per-index:
  /// - **incremental + non-unique**: O(1) `insert(vid, value)` /
  ///   `removeVid(vid)` directly on the index (currently `int_`
  ///   columns only — other typed columns fall back to rebuild).
  /// - **deferred + non-unique**: queue the rebuild for the next
  ///   [flushDeferredIndexUpdates].
  /// - **otherwise (unique or default)**: drop-and-rebuild inline.
  void afterNodeWrite(int vid, int keyId) {
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
        createNodeIndex(spec);
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
    final colType = _nodeProps.columnType(keyId);
    if (idx is IntEqualityRangeIndex && colType == ColumnType.int_) {
      if (_nodeProps.has(vid, keyId)) {
        idx.insert(vid, _nodeProps.getInt(vid, keyId));
      } else {
        idx.removeVid(vid);
      }
      return true;
    }
    return false;
  }

  /// Drop-and-rebuild (or incrementally remove) every registered node
  /// index — used when [vid] is deleted and its absence spans every
  /// column. Incremental int indexes drop the vid in O(1) without a
  /// full rebuild.
  void onNodeDeleted(int vid) {
    final names = _nodeIndexes.keys.toList();
    for (final name in names) {
      final idx = _nodeIndexes[name];
      if (idx == null) continue;
      final spec = idx.spec;
      final kind = spec.kind;
      if (kind is EqualityRange &&
          kind.incremental &&
          !kind.unique &&
          idx is IntEqualityRangeIndex) {
        idx.removeVid(vid);
        continue;
      }
      if (kind is EqualityRange && kind.deferred && !kind.unique) {
        _pendingNodeIndexFlush.add(spec.name);
      } else {
        _nodeIndexes.remove(spec.name);
        createNodeIndex(spec);
      }
    }
  }

  /// Number of deferred index rebuilds currently queued. Tests +
  /// observability use this; v1 doesn't expose a stream.
  int get pendingDeferredIndexUpdates => _pendingNodeIndexFlush.length;

  /// Async drain that uses the rebuild coordinator when set, falling
  /// back to the synchronous main-isolate rebuild otherwise.
  /// Worker-supported column types route through
  /// `PersistentWorker.send(...)`; unsupported types fall back per-index
  /// to the sync rebuild path so a mixed workload keeps making progress.
  Future<void> flushDeferredIndexUpdatesAsync() async {
    if (_pendingNodeIndexFlush.isEmpty) return;
    final coord = _coordinator();
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
    if (_pendingNodeIndexFlush.isEmpty) return;
    final pending = List<String>.of(_pendingNodeIndexFlush);
    _pendingNodeIndexFlush.clear();
    for (final name in pending) {
      final idx = _nodeIndexes[name];
      if (idx == null) continue;
      final spec = idx.spec;
      _nodeIndexes.remove(name);
      createNodeIndex(spec);
    }
  }

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
}
