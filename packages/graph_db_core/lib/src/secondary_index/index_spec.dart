/// Secondary-index registration types (plan §3.3).
library;

/// What kind of index to build. Sealed so v1 ships only [EqualityRange]
/// and future versions can add `FullText`, `Vector`, etc. without
/// breaking existing `createIndex` callers (plan §3.3).
sealed class IndexKind {
  const IndexKind();
}

/// Equality + range index — sorted parallel arrays `(value, vid)` with
/// an **optional** hash overlay (`Map<value, Uint32List>`) for cheap
/// equality lookups on high-cardinality columns (plan §3.3). Range
/// queries always go through the sorted array; the hash overlay is a
/// pure addition.
class EqualityRange extends IndexKind {
  /// Build a parallel hash map keyed by value. Pays memory for O(1)
  /// equality lookups; range queries remain on the sorted array. Useful
  /// on raw `string` columns and any high-cardinality column where
  /// equality dominates the workload.
  final bool hashOverlay;

  const EqualityRange({this.hashOverlay = false});

  @override
  String toString() =>
      'EqualityRange(hashOverlay: $hashOverlay)';
}

/// Registers an index with the engine. Single-property only in v1
/// (composite deferred — plan §3.3).
class IndexSpec {
  /// Human-readable name. Used as the registry key — must be unique
  /// per `MutableGraphState`.
  final String name;

  /// Interned prop key id (`GraphDb.internPropKey(...)`) to index over.
  /// Single-property only in v1.
  final int keyId;

  /// Index kind. v1 ships [EqualityRange] only.
  final IndexKind kind;

  const IndexSpec({
    required this.name,
    required this.keyId,
    required this.kind,
  });

  @override
  String toString() =>
      'IndexSpec(name: $name, keyId: $keyId, kind: $kind)';
}
