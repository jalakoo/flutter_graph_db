/// Secondary-index public interface + per-type sorted-array impls
///.
///
/// The shape mirrors the primitive read API: callers get
/// `lowerBound` / `upperBound` integer indices into [sortedVids] and
/// then index that array directly. Allocation-free on the hot path.
library;

import 'dart:typed_data';

import '../property_store.dart';
import 'index_spec.dart';

/// Common interface for every secondary index variant. Concrete
/// classes are per-column-type ([IntEqualityRangeIndex],
/// [DoubleEqualityRangeIndex], etc.); the registry only sees this
/// interface so it can store mixed-type indexes by name.
abstract class SecondaryIndex {
  /// The spec the user passed at creation.
  IndexSpec get spec;

  /// Approximate memory footprint, in bytes. Used by the registry to
  /// compute the size-budget ratio.
  int get sizeBytes;

  /// Number of (value, vid) entries in the index — excludes vids that
  /// are tombstoned or set to explicit NULL.
  int get length;

  /// The vid at sorted position [i].
  int vidAt(int i);

  /// View of the parallel-array vids. Same content as iterating
  /// [vidAt]; exposed for callers that need a `Uint32List` reference
  /// (e.g. to pass to a CSR overlay merge).
  Uint32List get sortedVids;

  /// True when the spec's [EqualityRange.unique] flag is set — the
  /// registry consults this to enforce uniqueness on every
  /// mutation that touches the indexed property.
  bool get isUnique;
}

// ---------------------------------------------------------------------------
// Binary-search helpers — typed arrays only, no boxing.
//
// `lowerBound` returns the smallest index `i` such that `vs[i] >= q`.
// `upperBound` returns the smallest index `i` such that `vs[i] >  q`.
// Equality range is `[lowerBound(q), upperBound(q))`.

// Note: `int_` columns are stored in `Float64List` (web has no
// `Int64List` — same compat reason as the `Uint32List` re-spec).
// Comparison between a `double` cell and an `int` query is exact for
// values < 2^53, which covers every realistic integer property.
int _lbInt(Float64List vs, int n, int q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid] < q) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _ubInt(Float64List vs, int n, int q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid] <= q) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _lbDouble(Float64List vs, int n, double q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid] < q) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _ubDouble(Float64List vs, int n, double q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid] <= q) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _lbU32(Uint32List vs, int n, int q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid] < q) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _ubU32(Uint32List vs, int n, int q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid] <= q) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _lbStr(List<String> vs, int n, String q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid].compareTo(q) < 0) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _ubStr(List<String> vs, int n, String q) {
  var lo = 0, hi = n;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (vs[mid].compareTo(q) <= 0) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

// ---------------------------------------------------------------------------
// Concrete impls per column type. Each is a thin parallel-array shape
// with a binary-search pair tuned to the value type.

/// Equality+range index over an `int_` column.
class IntEqualityRangeIndex implements SecondaryIndex {
  @override
  final IndexSpec spec;

  /// Sorted values, length == [length]. Index `i` pairs with
  /// [sortedVids] index `i`. Non-final: replaced lazily on the first
  /// range query after an incremental mutation.
  ///
  /// Stored as `Float64List` (web compat — see file-top note); each
  /// cell holds an integer ≤ 2^53. Read sites do `.toInt()` at the
  /// boundary so callers never see a double.
  Float64List sortedValues;

  @override
  Uint32List sortedVids;

  /// Hash overlay storage. Always present when the spec asks for
  /// `hashOverlay: true` OR `incremental: true`. Growable inner
  /// lists so incremental [insert] / [removeVid] can mutate in
  /// place; [equalsHash] copies to `Uint32List` on demand.
  Map<int, List<int>>? _hash;

  /// Reverse lookup `vid → currently-indexed value`. Populated only
  /// when the spec asks for `incremental: true`. Used by
  /// [removeVid] to find the old value's hash bucket in O(1).
  Map<int, int>? _vidToValue;

  /// `true` when an incremental mutation has invalidated the sorted
  /// arrays. Cleared by [_ensureSorted].
  bool _sortedDirty = false;

  IntEqualityRangeIndex._({
    required this.spec,
    required this.sortedValues,
    required this.sortedVids,
    required Map<int, List<int>>? hash,
    Map<int, int>? vidToValue,
  })  : _hash = hash,
        _vidToValue = vidToValue;

  /// Builds an instance from already-sorted typed arrays (used by the
  /// worker-isolate rebuild path so the result is byte-identical to a
  /// fresh `.build()`).
  factory IntEqualityRangeIndex.fromSorted({
    required IndexSpec spec,
    required Float64List sortedValues,
    required Uint32List sortedVids,
    required Map<int, Uint32List>? hash,
  }) {
    final mutHash = hash == null
        ? null
        : {for (final e in hash.entries) e.key: List<int>.of(e.value)};
    final incremental = (spec.kind as EqualityRange).incremental;
    Map<int, int>? vidToValue;
    if (incremental) {
      vidToValue = <int, int>{};
      for (var i = 0; i < sortedValues.length; i++) {
        vidToValue[sortedVids[i]] = sortedValues[i].toInt();
      }
    }
    final effectiveHash = mutHash ??
        (incremental ? _buildIntHashFromSorted(sortedValues, sortedVids) : null);
    return IntEqualityRangeIndex._(
      spec: spec,
      sortedValues: sortedValues,
      sortedVids: sortedVids,
      hash: effectiveHash,
      vidToValue: vidToValue,
    );
  }

  factory IntEqualityRangeIndex.build({
    required IndexSpec spec,
    required PropertyStore store,
    required bool hashOverlay,
  }) {
    final n = store.columnSetCount(spec.keyId);
    final values = Float64List(n);
    final vids = Uint32List(n);
    var idx = 0;
    store.forEachSetInt(spec.keyId, (v, value) {
      values[idx] = value.toDouble();
      vids[idx] = v;
      idx++;
    });
    final filled = idx;
    final pairs = List<int>.generate(filled, (i) => i)
      ..sort((a, b) {
        final c = values[a].compareTo(values[b]);
        return c != 0 ? c : vids[a].compareTo(vids[b]);
      });
    final sortedValues = Float64List(filled);
    final sortedVids = Uint32List(filled);
    for (var i = 0; i < filled; i++) {
      sortedValues[i] = values[pairs[i]];
      sortedVids[i] = vids[pairs[i]];
    }
    final incremental = (spec.kind as EqualityRange).incremental;
    final needHash = hashOverlay || incremental;
    final hash =
        needHash ? _buildIntHashFromSorted(sortedValues, sortedVids) : null;
    Map<int, int>? vidToValue;
    if (incremental) {
      vidToValue = <int, int>{};
      for (var i = 0; i < filled; i++) {
        vidToValue[sortedVids[i]] = sortedValues[i].toInt();
      }
    }
    return IntEqualityRangeIndex._(
      spec: spec,
      sortedValues: sortedValues,
      sortedVids: sortedVids,
      hash: hash,
      vidToValue: vidToValue,
    );
  }

  static Map<int, List<int>> _buildIntHashFromSorted(
    Float64List vs,
    Uint32List vids,
  ) {
    final out = <int, List<int>>{};
    for (var i = 0; i < vs.length; i++) {
      (out[vs[i].toInt()] ??= <int>[]).add(vids[i]);
    }
    return out;
  }

  @override
  int get length =>
      _vidToValue?.length ?? sortedVids.length;

  @override
  int vidAt(int i) {
    _ensureSorted();
    return sortedVids[i];
  }

  @override
  bool get isUnique => (spec.kind as EqualityRange).unique;

  @override
  int get sizeBytes {
    var n = 8 * sortedValues.length + 4 * sortedVids.length;
    final h = _hash;
    if (h != null) {
      for (final e in h.entries) {
        n += 8 + 4 * e.value.length;
      }
    }
    final v = _vidToValue;
    if (v != null) n += 16 * v.length; // rough — int↔int Map entries
    return n;
  }

  /// Smallest sorted index where value >= q. Triggers a lazy resort
  /// if a prior incremental mutation invalidated the sorted arrays.
  int lowerBound(int q) {
    _ensureSorted();
    return _lbInt(sortedValues, sortedValues.length, q);
  }

  /// Smallest sorted index where value > q.
  int upperBound(int q) {
    _ensureSorted();
    return _ubInt(sortedValues, sortedValues.length, q);
  }

  /// O(1) equality lookup via the hash overlay (always present in
  /// incremental mode; opt-in via `hashOverlay: true` otherwise).
  /// Returns `null` when the value isn't indexed or no overlay was
  /// built. Allocates a fresh `Uint32List` per call — callers
  /// iterating the result should hoist it out of inner loops.
  Uint32List? equalsHash(int q) {
    final b = _hash?[q];
    return b == null ? null : Uint32List.fromList(b);
  }

  // ----- Incremental mutations ---------------------------

  /// In-place insert of a `(vid, value)` pair. Requires
  /// `EqualityRange(incremental: true)` on the spec — throws
  /// otherwise. O(1) hash update + dirty-mark the sorted arrays.
  /// Re-inserting a vid that's already indexed updates its value
  /// (same semantics as `SET n.prop = x`).
  void insert(int vid, int value) {
    final v2v = _vidToValue;
    if (v2v == null) {
      throw StateError(
        'insert() requires EqualityRange(incremental: true) on the spec',
      );
    }
    final old = v2v[vid];
    if (old != null) {
      _removeFromHash(vid, old);
    }
    (_hash!.putIfAbsent(value, () => <int>[])).add(vid);
    v2v[vid] = value;
    _sortedDirty = true;
  }

  /// In-place removal of [vid]. No-op if absent. Requires incremental.
  void removeVid(int vid) {
    final v2v = _vidToValue;
    if (v2v == null) {
      throw StateError(
        'removeVid() requires EqualityRange(incremental: true) on the spec',
      );
    }
    final old = v2v.remove(vid);
    if (old == null) return;
    _removeFromHash(vid, old);
    _sortedDirty = true;
  }

  void _removeFromHash(int vid, int value) {
    final bucket = _hash![value];
    if (bucket == null) return;
    bucket.remove(vid);
    if (bucket.isEmpty) _hash!.remove(value);
  }

  /// Re-derives [sortedValues] / [sortedVids] from the current hash
  /// overlay. No-op when the index isn't dirty.
  void _ensureSorted() {
    if (!_sortedDirty) return;
    final v2v = _vidToValue!;
    final n = v2v.length;
    final entries = v2v.entries.toList()
      ..sort((a, b) {
        final c = a.value.compareTo(b.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final newValues = Float64List(n);
    final newVids = Uint32List(n);
    for (var i = 0; i < n; i++) {
      newValues[i] = entries[i].value.toDouble();
      newVids[i] = entries[i].key;
    }
    sortedValues = newValues;
    sortedVids = newVids;
    _sortedDirty = false;
  }
}

/// Equality+range index over a `double_` column.
class DoubleEqualityRangeIndex implements SecondaryIndex {
  @override
  final IndexSpec spec;
  final Float64List sortedValues;
  @override
  final Uint32List sortedVids;
  final Map<double, Uint32List>? _hash;

  DoubleEqualityRangeIndex._({
    required this.spec,
    required this.sortedValues,
    required this.sortedVids,
    required Map<double, Uint32List>? hash,
  }) : _hash = hash;

  factory DoubleEqualityRangeIndex.build({
    required IndexSpec spec,
    required PropertyStore store,
    required bool hashOverlay,
  }) {
    final n = store.columnSetCount(spec.keyId);
    final values = Float64List(n);
    final vids = Uint32List(n);
    var idx = 0;
    store.forEachSetDouble(spec.keyId, (v, value) {
      values[idx] = value;
      vids[idx] = v;
      idx++;
    });
    final filled = idx;
    final pairs = List<int>.generate(filled, (i) => i)
      ..sort((a, b) {
        final c = values[a].compareTo(values[b]);
        return c != 0 ? c : vids[a].compareTo(vids[b]);
      });
    final sortedValues = Float64List(filled);
    final sortedVids = Uint32List(filled);
    for (var i = 0; i < filled; i++) {
      sortedValues[i] = values[pairs[i]];
      sortedVids[i] = vids[pairs[i]];
    }
    final hash = hashOverlay
        ? _buildDoubleHash(sortedValues, sortedVids)
        : null;
    return DoubleEqualityRangeIndex._(
      spec: spec,
      sortedValues: sortedValues,
      sortedVids: sortedVids,
      hash: hash,
    );
  }

  static Map<double, Uint32List> _buildDoubleHash(
    Float64List vs,
    Uint32List vids,
  ) {
    final out = <double, List<int>>{};
    for (var i = 0; i < vs.length; i++) {
      (out[vs[i]] ??= <int>[]).add(vids[i]);
    }
    return {for (final e in out.entries) e.key: Uint32List.fromList(e.value)};
  }

  @override
  int get length => sortedVids.length;
  @override
  int vidAt(int i) => sortedVids[i];
  @override
  bool get isUnique => (spec.kind as EqualityRange).unique;
  @override
  int get sizeBytes =>
      8 * sortedValues.length +
      4 * sortedVids.length +
      (_hash == null
          ? 0
          : _hash!.entries
              .fold<int>(0, (acc, e) => acc + 8 + 4 * e.value.length));

  int lowerBound(double q) =>
      _lbDouble(sortedValues, sortedValues.length, q);
  int upperBound(double q) =>
      _ubDouble(sortedValues, sortedValues.length, q);
  Uint32List? equalsHash(double q) => _hash?[q];
}

/// Equality+range index over a `stringId` column (interned id is the
/// sort key, not the underlying string — callers wanting lexicographic
/// order on stringIds need a different design or a `string` column).
class StringIdEqualityRangeIndex implements SecondaryIndex {
  @override
  final IndexSpec spec;
  final Uint32List sortedValues;
  @override
  final Uint32List sortedVids;
  final Map<int, Uint32List>? _hash;

  StringIdEqualityRangeIndex._({
    required this.spec,
    required this.sortedValues,
    required this.sortedVids,
    required Map<int, Uint32List>? hash,
  }) : _hash = hash;

  factory StringIdEqualityRangeIndex.build({
    required IndexSpec spec,
    required PropertyStore store,
    required bool hashOverlay,
  }) {
    final n = store.columnSetCount(spec.keyId);
    final values = Uint32List(n);
    final vids = Uint32List(n);
    var idx = 0;
    store.forEachSetStringId(spec.keyId, (v, value) {
      values[idx] = value;
      vids[idx] = v;
      idx++;
    });
    final filled = idx;
    final pairs = List<int>.generate(filled, (i) => i)
      ..sort((a, b) {
        final c = values[a].compareTo(values[b]);
        return c != 0 ? c : vids[a].compareTo(vids[b]);
      });
    final sortedValues = Uint32List(filled);
    final sortedVids = Uint32List(filled);
    for (var i = 0; i < filled; i++) {
      sortedValues[i] = values[pairs[i]];
      sortedVids[i] = vids[pairs[i]];
    }
    final hash = hashOverlay ? _buildU32Hash(sortedValues, sortedVids) : null;
    return StringIdEqualityRangeIndex._(
      spec: spec,
      sortedValues: sortedValues,
      sortedVids: sortedVids,
      hash: hash,
    );
  }

  static Map<int, Uint32List> _buildU32Hash(
    Uint32List vs,
    Uint32List vids,
  ) {
    final out = <int, List<int>>{};
    for (var i = 0; i < vs.length; i++) {
      (out[vs[i]] ??= <int>[]).add(vids[i]);
    }
    return {for (final e in out.entries) e.key: Uint32List.fromList(e.value)};
  }

  @override
  int get length => sortedVids.length;
  @override
  int vidAt(int i) => sortedVids[i];
  @override
  bool get isUnique => (spec.kind as EqualityRange).unique;
  @override
  int get sizeBytes =>
      4 * sortedValues.length +
      4 * sortedVids.length +
      (_hash == null
          ? 0
          : _hash!.entries
              .fold<int>(0, (acc, e) => acc + 8 + 4 * e.value.length));

  int lowerBound(int q) => _lbU32(sortedValues, sortedValues.length, q);
  int upperBound(int q) => _ubU32(sortedValues, sortedValues.length, q);
  Uint32List? equalsHash(int q) => _hash?[q];
}

/// Equality+range index over a `string` column. Uses lexicographic
/// `String.compareTo` ordering (codepoint order).
class StringEqualityRangeIndex implements SecondaryIndex {
  @override
  final IndexSpec spec;
  final List<String> sortedValues;
  @override
  final Uint32List sortedVids;
  final Map<String, Uint32List>? _hash;

  StringEqualityRangeIndex._({
    required this.spec,
    required this.sortedValues,
    required this.sortedVids,
    required Map<String, Uint32List>? hash,
  }) : _hash = hash;

  factory StringEqualityRangeIndex.build({
    required IndexSpec spec,
    required PropertyStore store,
    required bool hashOverlay,
  }) {
    final n = store.columnSetCount(spec.keyId);
    final values = List<String>.filled(n, '', growable: false);
    final vids = Uint32List(n);
    var idx = 0;
    store.forEachSetString(spec.keyId, (v, value) {
      values[idx] = value;
      vids[idx] = v;
      idx++;
    });
    final filled = idx;
    final pairs = List<int>.generate(filled, (i) => i)
      ..sort((a, b) {
        final c = values[a].compareTo(values[b]);
        return c != 0 ? c : vids[a].compareTo(vids[b]);
      });
    final sortedValues =
        List<String>.filled(filled, '', growable: false);
    final sortedVids = Uint32List(filled);
    for (var i = 0; i < filled; i++) {
      sortedValues[i] = values[pairs[i]];
      sortedVids[i] = vids[pairs[i]];
    }
    final hash = hashOverlay
        ? _buildStrHash(sortedValues, sortedVids)
        : null;
    return StringEqualityRangeIndex._(
      spec: spec,
      sortedValues: sortedValues,
      sortedVids: sortedVids,
      hash: hash,
    );
  }

  static Map<String, Uint32List> _buildStrHash(
    List<String> vs,
    Uint32List vids,
  ) {
    final out = <String, List<int>>{};
    for (var i = 0; i < vs.length; i++) {
      (out[vs[i]] ??= <int>[]).add(vids[i]);
    }
    return {for (final e in out.entries) e.key: Uint32List.fromList(e.value)};
  }

  @override
  int get length => sortedVids.length;
  @override
  int vidAt(int i) => sortedVids[i];
  @override
  bool get isUnique => (spec.kind as EqualityRange).unique;
  @override
  int get sizeBytes {
    var stringBytes = 0;
    for (final s in sortedValues) {
      // 2 bytes per UTF-16 code unit + 16 byte header overhead — a
      // rough approximation good enough for the soft budget check.
      stringBytes += 16 + s.length * 2;
    }
    return stringBytes +
        4 * sortedVids.length +
        (_hash == null
            ? 0
            : _hash!.entries
                .fold<int>(0, (acc, e) => acc + 16 + 4 * e.value.length));
  }

  int lowerBound(String q) =>
      _lbStr(sortedValues, sortedValues.length, q);
  int upperBound(String q) =>
      _ubStr(sortedValues, sortedValues.length, q);
  Uint32List? equalsHash(String q) => _hash?[q];
}

/// Equality+range index over a `bool` column. Sorted-array degenerates
/// to a single cutoff index — `[0, cutoff)` are the `false`-vids and
/// `[cutoff, length)` are the `true`-vids. Equality is O(1) once
/// [_cutoff] is known; range is trivial.
///
/// The hash overlay flag is accepted for API uniformity but ignored —
/// `equalsHash` is no cheaper than the cutoff lookup, so the overlay
/// would just waste memory.
class BoolEqualityRangeIndex implements SecondaryIndex {
  @override
  final IndexSpec spec;
  @override
  final Uint32List sortedVids;
  final int cutoff;

  BoolEqualityRangeIndex._({
    required this.spec,
    required this.sortedVids,
    required this.cutoff,
  });

  factory BoolEqualityRangeIndex.build({
    required IndexSpec spec,
    required PropertyStore store,
  }) {
    final falses = <int>[];
    final trues = <int>[];
    store.forEachSetBool(spec.keyId, (v, value) {
      (value ? trues : falses).add(v);
    });
    falses.sort();
    trues.sort();
    final n = falses.length + trues.length;
    final sortedVids = Uint32List(n);
    for (var i = 0; i < falses.length; i++) {
      sortedVids[i] = falses[i];
    }
    for (var i = 0; i < trues.length; i++) {
      sortedVids[falses.length + i] = trues[i];
    }
    return BoolEqualityRangeIndex._(
      spec: spec,
      sortedVids: sortedVids,
      cutoff: falses.length,
    );
  }

  @override
  int get length => sortedVids.length;
  @override
  int vidAt(int i) => sortedVids[i];
  @override
  bool get isUnique => (spec.kind as EqualityRange).unique;

  /// 4 bytes per vid; no values array (the cutoff carries that
  /// information). 16 bytes overhead for the object header.
  @override
  int get sizeBytes => 4 * sortedVids.length + 16;

  /// First sorted index for the `false` arm.
  int falseStart() => 0;

  /// One past the last sorted index of the `false` arm — equal to
  /// [cutoff].
  int falseEnd() => cutoff;

  /// First sorted index for the `true` arm.
  int trueStart() => cutoff;

  /// One past the last sorted index of the `true` arm — equal to
  /// [length].
  int trueEnd() => sortedVids.length;

  /// Convenience — returns the slice for the given query value.
  /// Allocation-free.
  (int lo, int hi) equalRange(bool value) =>
      value ? (cutoff, sortedVids.length) : (0, cutoff);
}
