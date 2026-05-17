/// Secondary-index registration types.
library;

/// What kind of index to build. Sealed so v1 ships only [EqualityRange]
/// and future versions can add `FullText`, `Vector`, etc. without
/// breaking existing `createIndex` callers.
sealed class IndexKind {
  const IndexKind();
}

/// Equality + range index — sorted parallel arrays `(value, vid)` with
/// an **optional** hash overlay (`Map<value, Uint32List>`) for cheap
/// equality lookups on high-cardinality columns. Range
/// queries always go through the sorted array; the hash overlay is a
/// pure addition.
class EqualityRange extends IndexKind {
  /// Build a parallel hash map keyed by value. Pays memory for O(1)
  /// equality lookups; range queries remain on the sorted array. Useful
  /// on raw `string` columns and any high-cardinality column where
  /// equality dominates the workload.
  final bool hashOverlay;

  /// When `true`, the index enforces value uniqueness — a mutation
  /// that would create a second `(value, vid)` pair with the same
  /// value (and a different vid) throws `ConstraintViolation`. Unique
  /// indexes update synchronously; the deferred (worker-isolate) path
  /// is reserved for non-unique indexes only.
  final bool unique;

  /// When `true` AND `unique` is `false`, mutations queue an update
  /// instead of rebuilding the index inline. Callers drain pending
  /// updates by calling `state.flushDeferredIndexUpdates()` before any
  /// read that must see the latest state. Worker-isolate offload of
  /// the actual rebuild is a polish follow-up — today's flush runs
  /// synchronously but coalesces multiple updates into one rebuild
  /// per index.
  final bool deferred;

  /// When `true`, the index supports O(1) in-place `insert(vid, value)`
  /// / `removeVid(vid)` for the typed concrete classes that implement
  /// it.
  /// Equality lookups stay O(1) via the always-on hash overlay; range
  /// lookups lazily re-sort on first call after a mutation. Pays
  /// extra memory for the permanent hash + vid↔value maps (~3×
  /// the immutable index footprint on int columns).
  final bool incremental;

  /// Hint to the persistence layer. When
  /// `priority: high` the index is intended to be persisted
  /// alongside the engine snapshot so a fresh open does
  /// not pay the rebuild cost. Default rebuilds on startup. The
  /// flag is honoured by `IndexSpec.priority`; **the actual
  /// persistence wiring lands with snapshot integration** and is
  /// tracked separately.
  const EqualityRange({
    this.hashOverlay = false,
    this.unique = false,
    this.deferred = false,
    this.incremental = false,
  });

  @override
  String toString() =>
      'EqualityRange(hashOverlay: $hashOverlay, unique: $unique)';
}

/// Persistence priority. `low` (default) rebuilds
/// on startup; `high` persists alongside the engine snapshot
/// (snapshot integration is a future enhancement).
enum IndexPriority { low, high }

/// Registers an index with the engine. Single-property only in v1
/// (composite deferred).
class IndexSpec {
  /// Human-readable name. Used as the registry key — must be unique
  /// per `MutableGraphState`.
  final String name;

  /// Interned prop key id (`GraphDb.internPropKey(...)`) to index over.
  /// Single-property only in v1.
  final int keyId;

  /// Index kind. v1 ships [EqualityRange] only.
  final IndexKind kind;

  /// Persistence priority. Default [IndexPriority.low].
  final IndexPriority priority;

  const IndexSpec({
    required this.name,
    required this.keyId,
    required this.kind,
    this.priority = IndexPriority.low,
  });

  @override
  String toString() =>
      'IndexSpec(name: $name, keyId: $keyId, kind: $kind, '
      'priority: ${priority.name})';
}
