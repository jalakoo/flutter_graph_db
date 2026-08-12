/// Secondary-index registration types.
library;

import '../property_store.dart' show ColumnType;

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

/// Persistence priority.
///
/// Index *declarations* are journaled and restored on every open
/// regardless of this flag — an index no longer disappears on restart.
/// What `priority` controls is whether the rebuild cost is paid at open:
/// `low` (default) rebuilds the contents from the recovered columns;
/// `high` is reserved for persisting the built arrays alongside the
/// snapshot so a fresh open skips the rebuild. **The `high` fast path is
/// not implemented yet** — it currently behaves as `low`.
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

  /// Optional explicit column type. The engine normally infers the type
  /// from the column — but columns are created lazily on first write, so
  /// on an **empty graph** no column exists yet and the engine can't pick
  /// an index implementation. Declaring [valueType] lets you build the
  /// index ahead of any writes: the engine creates the (empty) column of
  /// this type, so the index is live from creation and a later write of a
  /// different type to [keyId] is rejected. Leave `null` to index an
  /// already-populated column (the default, data-driven path).
  final ColumnType? valueType;

  /// Restricts **unique enforcement** to nodes carrying this label id.
  /// `null` (default) enforces across every node, regardless of label.
  ///
  /// This is how a Neo4j-style `UNIQUE (Label, key)` constraint is
  /// scoped: `declareConstraint` sets it to the constraint's `labelId`,
  /// so writing a duplicate value to a node that does *not* carry that
  /// label is allowed. Before this existed, the auto-created backing
  /// index was global and rejected such writes.
  ///
  /// Only enforcement is scoped — the index itself still covers every
  /// row of the column, so lookups against it are a superset. That keeps
  /// the index build label-agnostic (and correct as labels change under
  /// `SetNodeLabels`) at the cost of scanning the equal range at
  /// enforcement time.
  ///
  /// Meaningless on an edge index; edges carry a type, not labels.
  final int? labelScope;

  const IndexSpec({
    required this.name,
    required this.keyId,
    required this.kind,
    this.priority = IndexPriority.low,
    this.valueType,
    this.labelScope,
  });

  @override
  String toString() =>
      'IndexSpec(name: $name, keyId: $keyId, kind: $kind, '
      'priority: ${priority.name}, valueType: $valueType, '
      'labelScope: $labelScope)';
}
