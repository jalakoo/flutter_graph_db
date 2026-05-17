/// Constraint catalog — owns registered [ConstraintSpec]s + the
/// mutation enforcement loop.
///
/// The catalog is a thin wrapper around a `Map<String, ConstraintSpec>`
/// — naming + lookup + iteration. Enforcement methods are pure
/// functions that the [MutableGraphState] mutation hooks call.
library;

import '../exceptions.dart';
import '../prop_value.dart';
import '../property_store.dart';
import 'constraint.dart';

class ConstraintCatalog {
  final Map<String, ConstraintSpec> _byName = {};

  /// Registers [spec]. Throws [ConstraintViolation] if a constraint
  /// with the same name is already declared.
  void declare(ConstraintSpec spec) {
    if (_byName.containsKey(spec.name)) {
      throw ConstraintViolation(
        'constraint "${spec.name}" already declared',
      );
    }
    _byName[spec.name] = spec;
  }

  /// Removes [name]. No-op if absent (matches the /// `DropConstraint` semantics — idempotent drop).
  void drop(String name) => _byName.remove(name);

  ConstraintSpec? get(String name) => _byName[name];

  Iterable<ConstraintSpec> get all => _byName.values;

  int get length => _byName.length;

  // ----- Enforcement helpers (called by MutableGraphState mutation hooks) -

  /// Checks every active [ExistenceConstraint] on [labelId] —
  /// throws [ConstraintViolation] if any required key is missing
  /// from [props].
  void enforceExistenceOnAddNode({
    required int labelId,
    required Map<int, PropValue> props,
  }) {
    for (final c in _byName.values) {
      if (c is! ExistenceConstraint) continue;
      if (c.labelId != labelId) continue;
      if (!props.containsKey(c.keyId)) {
        throw ConstraintViolation(
          'existence constraint "${c.name}" violated: '
          'node with label $labelId missing key ${c.keyId}',
        );
      }
    }
  }

  /// Checks every active [ExistenceConstraint] before a property is
  /// removed — throws if [vid] still carries the constrained label
  /// AND [keyId] is the constrained key.
  void enforceExistenceOnDelNodeProp({
    required int vid,
    required int keyId,
    required int Function(int vid) labelOf,
  }) {
    for (final c in _byName.values) {
      if (c is! ExistenceConstraint) continue;
      if (c.keyId != keyId) continue;
      if (labelOf(vid) == c.labelId) {
        throw ConstraintViolation(
          'existence constraint "${c.name}" violated: '
          'cannot remove key $keyId from vid $vid '
          '(still carries label ${c.labelId})',
        );
      }
    }
  }

  /// Returns true if any [UniqueConstraint] covers `(labelId,
  /// keyId)`. The unique-index enforcement already
  /// covers correctness for the SET path; this helper lets the
  /// catalog wire matching constraints to underlying unique
  /// indexes on `declareConstraint`.
  bool hasUniqueOn({required int labelId, required int keyId}) {
    for (final c in _byName.values) {
      if (c is UniqueConstraint &&
          c.labelId == labelId &&
          c.keyId == keyId) {
        return true;
      }
    }
    return false;
  }

  /// Iterates uniques that touch the given keyId (the label scope
  /// is checked at enforcement time).
  Iterable<UniqueConstraint> uniquesOnKey(int keyId) sync* {
    for (final c in _byName.values) {
      if (c is UniqueConstraint && c.keyId == keyId) yield c;
    }
  }

  void clear() => _byName.clear();
}

/// Used by the catalog enforcement to look up a node's effective
/// label without reaching into [PropertyStore]. The catalog is in
/// a sibling subdirectory; this typedef is the shared signature.
typedef LabelOfVid = int Function(int vid);
