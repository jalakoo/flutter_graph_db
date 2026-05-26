import 'graph_db.dart';
import 'ids.dart';
import 'prop_value.dart';
import 'property_store.dart' show ColumnType;

/// A reusable, immutable handle map over a [GraphDb]'s catalog — the spine
/// of the ergonomic API tier. Built once via [GraphDb.defineSchema], which
/// interns the labels / edge types / property keys and reserves a typed
/// node column for each declared prop key, then caches the integer handles
/// for the session.
///
/// Interned ids are monotonic and never change, so a [GraphSchema] is
/// build-once and never goes stale — it caches no scan results, only
/// handles. Re-create it on each open: a matching column declaration
/// no-ops, a conflicting one throws (the recovery fail-fast).
///
/// Lookups throw [ArgumentError] for a name that was not declared — the
/// handle set is closed. (Writing an *undeclared* property key is still
/// allowed via the ergonomic write path; it falls back to strict-by-Dart
/// boxing. Declared keys are the typed ones.)
class GraphSchema {
  /// The engine this schema is bound to.
  final GraphDb db;

  final Map<String, int> _labels;
  final Map<String, int> _edgeTypes;
  final Map<String, int> _propKeys;

  GraphSchema._(this.db, this._labels, this._edgeTypes, this._propKeys);

  /// Builds a schema against [db]. Prefer [GraphDb.defineSchema]. Interns
  /// every name and reserves a typed column for each entry of [propKeys]
  /// (via [GraphDb.declareNodeColumn]) — non-transactional schema ops.
  factory GraphSchema(
    GraphDb db, {
    Set<String> labels = const {},
    Set<String> edgeTypes = const {},
    Map<String, ColumnType> propKeys = const {},
  }) {
    final labelIds = {for (final l in labels) l: db.internLabel(l)};
    final edgeTypeIds = {for (final e in edgeTypes) e: db.internEdgeType(e)};
    final propKeyIds = <String, int>{};
    propKeys.forEach((name, type) {
      final id = db.internPropKey(name);
      propKeyIds[name] = id;
      db.declareNodeColumn(id, type); // eager + fail-fast on conflict
    });
    return GraphSchema._(db, labelIds, edgeTypeIds, propKeyIds);
  }

  /// The interned label id for [name]. Throws [ArgumentError] if [name]
  /// was not declared in [GraphDb.defineSchema].
  int label(String name) =>
      _labels[name] ?? (throw ArgumentError('label "$name" not in schema'));

  /// The interned edge-type id for [name]. Throws if not declared.
  int edgeType(String name) =>
      _edgeTypes[name] ??
      (throw ArgumentError('edge type "$name" not in schema'));

  /// The interned property-key id for [name]. Throws if not declared.
  int propKey(String name) =>
      _propKeys[name] ??
      (throw ArgumentError('prop key "$name" not in schema'));

  /// Adds a node with [label] and raw-valued [props] in its own
  /// transaction, returning the new [Vid]. Each value is boxed per its
  /// column type via [boxValue]: a declared (or already-written) column
  /// coerces — `int`→`double` promotes losslessly, lossy or mismatched
  /// types throw — while an undeclared key is interned and boxed strictly
  /// by its Dart type. `null` stores as `PropNull`.
  Future<Vid> add(
    String label,
    Map<String, Object?> props, {
    String? logicalId,
  }) async {
    final labelId = this.label(label);
    final boxed = <int, PropValue>{};
    props.forEach((name, raw) {
      final keyId = _propKeys[name] ?? db.internPropKey(name);
      boxed[keyId] = boxValue(raw, db.nodePropType(keyId));
    });
    return db.runTransaction((tx) =>
        tx.addNode(labelIds: [labelId], props: boxed, logicalId: logicalId));
  }

  /// Out-neighbours of [v] reached by an edge of type [edgeType]
  /// (read-your-writes). Replaces the hand-written `forEachOutNeighbor` +
  /// `if (type == …)` filter loop.
  List<Vid> outNeighbors(Vid v, String edgeType) {
    final t = this.edgeType(edgeType);
    final out = <Vid>[];
    db.forEachOutNeighbor(v, (dst, _, et) {
      if (et == t) out.add(dst);
    });
    return out;
  }

  /// In-neighbours of [v] reached by an edge of type [edgeType].
  List<Vid> inNeighbors(Vid v, String edgeType) {
    final t = this.edgeType(edgeType);
    final out = <Vid>[];
    db.forEachInNeighbor(v, (src, _, et) {
      if (et == t) out.add(src);
    });
    return out;
  }

  /// First node whose [propKey] equals [value], or `null`. The query
  /// [value] is boxed with the key's column type via the same [boxValue]
  /// that [add] uses, so a raw `3` matches a stored `3.0` in a double
  /// column. Pass [label] to scope the scan to one label. Returns `null`
  /// if [propKey] was never used (no such column).
  Vid? find(String propKey, Object value, {String? label}) {
    final keyId = _propKeys[propKey] ?? db.propKeyId(propKey);
    if (keyId == null) return null;
    final labelId = label == null ? null : this.label(label);
    return db.findNodeByProp(keyId, boxValue(value, db.nodePropType(keyId)),
        label: labelId);
  }

  /// All nodes whose [propKey] equals [value], ascending by vid. See
  /// [find]; empty if [propKey] was never used.
  List<Vid> findAll(String propKey, Object value, {String? label}) {
    final keyId = _propKeys[propKey] ?? db.propKeyId(propKey);
    if (keyId == null) return const [];
    final labelId = label == null ? null : this.label(label);
    return db.findNodesByProp(keyId, boxValue(value, db.nodePropType(keyId)),
        label: labelId);
  }
}

/// Boxes a raw Dart [value] for a column of [target] type, or `target`
/// `null` for an undeclared key (strict-by-Dart-type). The single coercion
/// point shared by [GraphSchema.add] and the finders, so query boxing
/// matches write boxing. Lossless `int`→`double` promotion only; lossy or
/// mismatched types throw [ArgumentError]. `null` → [PropNull].
PropValue boxValue(Object? value, ColumnType? target) {
  if (value == null) return const PropNull();
  switch (target) {
    case null:
      return _strictBox(value);
    case ColumnType.int_:
      if (value is int) return PropInt(value);
      throw ArgumentError(
          'expected int for an int column, got ${value.runtimeType}');
    case ColumnType.double_:
      if (value is double) return PropDouble(value);
      if (value is int) return PropDouble(value.toDouble()); // lossless promote
      throw ArgumentError('expected double or int for a double column, '
          'got ${value.runtimeType}');
    case ColumnType.bool_:
      if (value is bool) return PropBool(value);
      throw ArgumentError(
          'expected bool for a bool column, got ${value.runtimeType}');
    case ColumnType.string:
    case ColumnType.stringId:
      if (value is String) return PropString(value);
      throw ArgumentError(
          'expected String for a string column, got ${value.runtimeType}');
  }
}

PropValue _strictBox(Object value) {
  if (value is int) return PropInt(value);
  if (value is double) return PropDouble(value);
  if (value is bool) return PropBool(value);
  if (value is String) return PropString(value);
  throw ArgumentError(
      'unsupported value type for a graph property: ${value.runtimeType}');
}
