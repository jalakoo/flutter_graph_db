import 'dart:typed_data';

import 'exceptions.dart';
import 'prop_value.dart';

/// What kind of value a property column holds (plan §3.2).
///
/// The columnar property store stores scalar types only. `PropList` and
/// `PropMap` (boundary types in §5) are not stored in columns in v1.
///
/// `string` is the raw-string variant for unbounded-cardinality string
/// properties (plan §3.5). `stringId` is reserved for the future
/// dictionary-encoded low-cardinality variant — not yet exercised.
enum ColumnType { int_, double_, bool_, string, stringId }

/// One per-key column (plan §3.2):
///
/// - `values`         : typed array, compact, length = setCount
/// - `vidToSlot`      : per-vid index into `values`; sentinel `_absent`
///                       means "key not set on this vid"
/// - `isNull` bitmap  : bit set ⇒ key is set but value is `PropNull`
class _Column {
  static const int _absent = 0xFFFFFFFF;

  final ColumnType type;
  final int vidSpace;

  /// `Int64List` / `Float64List` / `Uint8List` (bool) / `Uint32List`
  /// (interned string id) depending on [type].
  Object values;

  /// Length [vidSpace]. `_absent` ⇒ key not set on this vid.
  final Uint32List vidToSlot;

  /// Bitmap of [capacity] bits. Bit `i` set ⇒ slot `i` is explicit null.
  Uint32List isNull;

  int setCount = 0;
  int capacity;

  _Column(this.type, this.vidSpace, int initialCapacity)
      : capacity = initialCapacity,
        values = _makeValues(type, initialCapacity),
        vidToSlot = Uint32List(vidSpace)..fillRange(0, vidSpace, _absent),
        isNull = Uint32List(_bitmapWords(initialCapacity));

  static int _bitmapWords(int bits) => (bits + 31) >> 5;

  static Object _makeValues(ColumnType type, int cap) {
    switch (type) {
      case ColumnType.int_:
        return Int64List(cap);
      case ColumnType.double_:
        return Float64List(cap);
      case ColumnType.bool_:
        return Uint8List(cap);
      case ColumnType.string:
        return List<String?>.filled(cap, null, growable: false);
      case ColumnType.stringId:
        return Uint32List(cap);
    }
  }

  void _grow() {
    final newCap = capacity * 2;
    Object newValues;
    switch (type) {
      case ColumnType.int_:
        final n = Int64List(newCap);
        n.setRange(0, capacity, values as Int64List);
        newValues = n;
      case ColumnType.double_:
        final n = Float64List(newCap);
        n.setRange(0, capacity, values as Float64List);
        newValues = n;
      case ColumnType.bool_:
        final n = Uint8List(newCap);
        n.setRange(0, capacity, values as Uint8List);
        newValues = n;
      case ColumnType.string:
        final n = List<String?>.filled(newCap, null, growable: false);
        n.setRange(0, capacity, values as List<String?>);
        newValues = n;
      case ColumnType.stringId:
        final n = Uint32List(newCap);
        n.setRange(0, capacity, values as Uint32List);
        newValues = n;
    }
    values = newValues;
    final newIsNull = Uint32List(_bitmapWords(newCap));
    newIsNull.setRange(0, isNull.length, isNull);
    isNull = newIsNull;
    capacity = newCap;
  }

  int allocSlot(int vid) {
    var slot = vidToSlot[vid];
    if (slot == _absent) {
      if (setCount == capacity) _grow();
      slot = setCount++;
      vidToSlot[vid] = slot;
      // New slot — clear the isNull bit (writer will set it if needed).
      _clearNull(slot);
    }
    return slot;
  }

  void tombstone(int vid) {
    vidToSlot[vid] = _absent;
    // Slot in `values` is leaked until a future compaction; OK for v0.
  }

  bool isSet(int vid) => vidToSlot[vid] != _absent;

  bool isExplicitNull(int slot) =>
      (isNull[slot >> 5] & (1 << (slot & 31))) != 0;

  void _setNull(int slot) {
    isNull[slot >> 5] |= 1 << (slot & 31);
  }

  void _clearNull(int slot) {
    isNull[slot >> 5] &= ~(1 << (slot & 31));
  }
}

/// Per-key columnar property store (plan §3.2, Option A).
///
/// Storage is **raw typed columns** — `PropValue` (plan §5) is never on
/// the hot read path. Each key has its column type fixed at first write
/// (`type-locked per key`); a later write of an incompatible type raises
/// [ConstraintViolation]. To intentionally change a key's type, call
/// [dropColumn] first.
///
/// Edges share the same shape, keyed by `eid` and constructed against a
/// separate `eidSpace` value (or use a second [PropertyStore] instance).
class PropertyStore {
  /// Upper bound on `vid` (or `eid`) values this store handles.
  final int vidSpace;

  final Map<int, _Column> _columns = {};

  PropertyStore({required this.vidSpace});

  // ---------------------------------------------------------------- catalog

  /// Explicitly declares a column for [keyId] with [type]. Useful when
  /// the first write would be [setNull] (which cannot infer a type).
  void createColumn(int keyId, ColumnType type) {
    final existing = _columns[keyId];
    if (existing != null) {
      if (existing.type == type) return;
      throw ConstraintViolation(
          'column $keyId already exists with type ${existing.type}, '
          'cannot redeclare as $type — drop it first');
    }
    _columns[keyId] = _Column(type, vidSpace, 16);
  }

  /// Clears all values for [keyId] and releases the column's type lock.
  /// The next write re-locks the column at the new type. Plan §3.2 /
  /// §5 documented escape hatch for intentional type changes.
  void dropColumn(int keyId) {
    _columns.remove(keyId);
  }

  bool hasColumn(int keyId) => _columns.containsKey(keyId);
  ColumnType? columnType(int keyId) => _columns[keyId]?.type;
  int get columnCount => _columns.length;

  // ---------------------------------------------------------------- writes

  void setInt(int vid, int keyId, int value) {
    final col = _columnFor(keyId, ColumnType.int_);
    final slot = col.allocSlot(vid);
    col._clearNull(slot);
    (col.values as Int64List)[slot] = value;
  }

  void setDouble(int vid, int keyId, double value) {
    final col = _columnFor(keyId, ColumnType.double_);
    final slot = col.allocSlot(vid);
    col._clearNull(slot);
    (col.values as Float64List)[slot] = value;
  }

  void setBool(int vid, int keyId, bool value) {
    final col = _columnFor(keyId, ColumnType.bool_);
    final slot = col.allocSlot(vid);
    col._clearNull(slot);
    (col.values as Uint8List)[slot] = value ? 1 : 0;
  }

  void setString(int vid, int keyId, String value) {
    final col = _columnFor(keyId, ColumnType.string);
    final slot = col.allocSlot(vid);
    col._clearNull(slot);
    (col.values as List<String?>)[slot] = value;
  }

  void setStringId(int vid, int keyId, int stringId) {
    final col = _columnFor(keyId, ColumnType.stringId);
    final slot = col.allocSlot(vid);
    col._clearNull(slot);
    (col.values as Uint32List)[slot] = stringId;
  }

  /// Writes an explicit `PropNull` to `(vid, keyId)`. Requires the
  /// column to already exist — [PropNull] carries no type, so the type
  /// lock cannot be inferred from a null-only key. Call [createColumn]
  /// first if needed.
  void setNull(int vid, int keyId) {
    final col = _columns[keyId];
    if (col == null) {
      throw ConstraintViolation(
          'cannot setNull on key $keyId: no column declared yet '
          '(call createColumn first, or set a typed value)');
    }
    final slot = col.allocSlot(vid);
    col._setNull(slot);
  }

  /// Removes `(vid, keyId)` entirely — key becomes "not set on this
  /// vid". Different from `setNull` (which keeps the key set, value is
  /// explicit null).
  void remove(int vid, int keyId) {
    _columns[keyId]?.tombstone(vid);
  }

  _Column _columnFor(int keyId, ColumnType requestedType) {
    final existing = _columns[keyId];
    if (existing == null) {
      // First write infers + locks the column type.
      final fresh = _Column(requestedType, vidSpace, 16);
      _columns[keyId] = fresh;
      return fresh;
    }
    if (existing.type != requestedType) {
      throw ConstraintViolation(
          'column $keyId is locked to ${existing.type}, '
          'cannot write $requestedType — call dropPropertyColumn first '
          'to change the type');
    }
    return existing;
  }

  // ---------------------------------------------------------------- reads
  //
  // Raw accessors — never allocate, never return a `PropValue`. Caller
  // is expected to know the column type (`columnType(keyId)`) or use
  // [has] / [isNull] first.

  bool has(int vid, int keyId) {
    final col = _columns[keyId];
    return col != null && col.isSet(vid);
  }

  bool isNull(int vid, int keyId) {
    final col = _columns[keyId];
    if (col == null) return false;
    final slot = col.vidToSlot[vid];
    if (slot == _Column._absent) return false;
    return col.isExplicitNull(slot);
  }

  int getInt(int vid, int keyId) =>
      (_assertReadable(vid, keyId, ColumnType.int_).values as Int64List)[
          _columns[keyId]!.vidToSlot[vid]];

  double getDouble(int vid, int keyId) =>
      (_assertReadable(vid, keyId, ColumnType.double_).values as Float64List)[
          _columns[keyId]!.vidToSlot[vid]];

  bool getBool(int vid, int keyId) =>
      (_assertReadable(vid, keyId, ColumnType.bool_).values as Uint8List)[
              _columns[keyId]!.vidToSlot[vid]] !=
          0;

  String getString(int vid, int keyId) =>
      (_assertReadable(vid, keyId, ColumnType.string).values as List<String?>)[
          _columns[keyId]!.vidToSlot[vid]]!;

  int getStringId(int vid, int keyId) =>
      (_assertReadable(vid, keyId, ColumnType.stringId).values as Uint32List)[
          _columns[keyId]!.vidToSlot[vid]];

  _Column _assertReadable(int vid, int keyId, ColumnType expected) {
    final col = _columns[keyId];
    if (col == null) {
      throw NotFoundException('no column for key $keyId');
    }
    if (col.type != expected) {
      throw ConstraintViolation(
          'column $keyId is ${col.type}, not $expected');
    }
    if (!col.isSet(vid)) {
      throw NotFoundException(
          'key $keyId not set on vid $vid (check has() first)');
    }
    return col;
  }

  // -------------------------------------------------------- bulk scans
  //
  // Used by the secondary-index builder (plan §3.3). Each scan visits
  // every vid where the column is set AND **not** explicit-null. v1
  // indexes do not include a NULL bucket; standard SQL-ish convention.
  // Allocation-free — typed value handed straight to [visit].

  int columnSetCount(int keyId) => _columns[keyId]?.setCount ?? 0;

  void forEachSetInt(int keyId, void Function(int vid, int value) visit) {
    final col = _assertColumnType(keyId, ColumnType.int_);
    if (col == null) return;
    final vals = col.values as Int64List;
    final vidSlot = col.vidToSlot;
    for (var v = 0; v < vidSlot.length; v++) {
      final s = vidSlot[v];
      if (s == _Column._absent) continue;
      if (col.isExplicitNull(s)) continue;
      visit(v, vals[s]);
    }
  }

  void forEachSetDouble(int keyId, void Function(int vid, double value) visit) {
    final col = _assertColumnType(keyId, ColumnType.double_);
    if (col == null) return;
    final vals = col.values as Float64List;
    final vidSlot = col.vidToSlot;
    for (var v = 0; v < vidSlot.length; v++) {
      final s = vidSlot[v];
      if (s == _Column._absent) continue;
      if (col.isExplicitNull(s)) continue;
      visit(v, vals[s]);
    }
  }

  void forEachSetBool(int keyId, void Function(int vid, bool value) visit) {
    final col = _assertColumnType(keyId, ColumnType.bool_);
    if (col == null) return;
    final vals = col.values as Uint8List;
    final vidSlot = col.vidToSlot;
    for (var v = 0; v < vidSlot.length; v++) {
      final s = vidSlot[v];
      if (s == _Column._absent) continue;
      if (col.isExplicitNull(s)) continue;
      visit(v, vals[s] != 0);
    }
  }

  void forEachSetString(int keyId, void Function(int vid, String value) visit) {
    final col = _assertColumnType(keyId, ColumnType.string);
    if (col == null) return;
    final vals = col.values as List<String?>;
    final vidSlot = col.vidToSlot;
    for (var v = 0; v < vidSlot.length; v++) {
      final s = vidSlot[v];
      if (s == _Column._absent) continue;
      if (col.isExplicitNull(s)) continue;
      visit(v, vals[s]!);
    }
  }

  void forEachSetStringId(
    int keyId,
    void Function(int vid, int stringId) visit,
  ) {
    final col = _assertColumnType(keyId, ColumnType.stringId);
    if (col == null) return;
    final vals = col.values as Uint32List;
    final vidSlot = col.vidToSlot;
    for (var v = 0; v < vidSlot.length; v++) {
      final s = vidSlot[v];
      if (s == _Column._absent) continue;
      if (col.isExplicitNull(s)) continue;
      visit(v, vals[s]);
    }
  }

  _Column? _assertColumnType(int keyId, ColumnType expected) {
    final col = _columns[keyId];
    if (col == null) return null;
    if (col.type != expected) {
      throw ConstraintViolation(
          'column $keyId is ${col.type}, not $expected');
    }
    return col;
  }

  /// Boundary read — constructs and returns a [PropValue]. Allocates;
  /// use the typed primitive accessors on the hot path.
  PropValue? getBoxed(int vid, int keyId) {
    final col = _columns[keyId];
    if (col == null) return null;
    final slot = col.vidToSlot[vid];
    if (slot == _Column._absent) return null;
    if (col.isExplicitNull(slot)) return const PropNull();
    switch (col.type) {
      case ColumnType.int_:
        return PropInt((col.values as Int64List)[slot]);
      case ColumnType.double_:
        return PropDouble((col.values as Float64List)[slot]);
      case ColumnType.bool_:
        return PropBool((col.values as Uint8List)[slot] != 0);
      case ColumnType.string:
        return PropString((col.values as List<String?>)[slot]!);
      case ColumnType.stringId:
        // Caller must decode the interned id through StringInterner —
        // the property store does not depend on the interner.
        return PropInt((col.values as Uint32List)[slot]);
    }
  }
}
