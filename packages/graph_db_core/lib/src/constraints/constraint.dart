/// Constraint catalog.
///
/// Sealed hierarchy — every spec is one of [UniqueConstraint] or
/// [ExistenceConstraint]. The catalog is replayed from the WAL via
/// the `DeclareConstraint` / `DropConstraint` ops so a
/// recovered engine starts with the same constraints active.
///
/// **Single-property only in v1.** Composite (label, key1, key2)
/// constraints are deferred; the spec carries one keyId.
library;

sealed class ConstraintSpec {
  /// Stable name — catalog key + the user-facing handle for
  /// `dropConstraint(name)`.
  final String name;

  /// Interned label id this constraint applies to. Together with
  /// [keyId] this scopes the constraint to one column on one label.
  final int labelId;

  /// Interned property key id.
  final int keyId;

  const ConstraintSpec({
    required this.name,
    required this.labelId,
    required this.keyId,
  });
}

/// "No two distinct nodes carrying [labelId] may share the same
/// value for [keyId]." Enforced at every `applyAddNode` /
/// `applySetNodeProp` that touches the column — implemented in
/// terms of the unique-index machinery so the check is O(log n) via
/// the index's binary search.
final class UniqueConstraint extends ConstraintSpec {
  const UniqueConstraint({
    required super.name,
    required super.labelId,
    required super.keyId,
  });
}

/// "Every node carrying [labelId] must have a value set for
/// [keyId]." Enforced at every `applyAddNode` (must include the
/// key in props) and every `applyDelNodeProp` (rejects removal if
/// the node still carries [labelId]).
final class ExistenceConstraint extends ConstraintSpec {
  const ExistenceConstraint({
    required super.name,
    required super.labelId,
    required super.keyId,
  });
}
