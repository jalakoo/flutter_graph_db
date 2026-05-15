/// Sealed property value hierarchy (plan §5).
///
/// **Boundary-only.** The storage core works in raw typed columns
/// (§3.2). `PropValue` is constructed at the public API boundary — in
/// GQL `RETURN`, in the object-graph wrapper, and for `WalOp` encoding.
/// Reads off the hot path never box; per-read boxing was measured at ~8×
/// the raw accessor on device (Spike A).
sealed class PropValue {
  const PropValue();
}

final class PropInt extends PropValue {
  final int value;
  const PropInt(this.value);

  @override
  bool operator ==(Object other) => other is PropInt && other.value == value;
  @override
  int get hashCode => Object.hash(PropInt, value);
  @override
  String toString() => 'PropInt($value)';
}

final class PropDouble extends PropValue {
  final double value;
  const PropDouble(this.value);

  @override
  bool operator ==(Object other) =>
      other is PropDouble && other.value == value;
  @override
  int get hashCode => Object.hash(PropDouble, value);
  @override
  String toString() => 'PropDouble($value)';
}

final class PropString extends PropValue {
  final String value;
  const PropString(this.value);

  @override
  bool operator ==(Object other) =>
      other is PropString && other.value == value;
  @override
  int get hashCode => Object.hash(PropString, value);
  @override
  String toString() => 'PropString($value)';
}

final class PropBool extends PropValue {
  final bool value;
  const PropBool(this.value);

  @override
  bool operator ==(Object other) => other is PropBool && other.value == value;
  @override
  int get hashCode => Object.hash(PropBool, value);
  @override
  String toString() => 'PropBool($value)';
}

/// Explicit null — distinct from "key not set" (plan §5). The property
/// store tracks the absence/explicit-null distinction via per-key
/// presence + `isNull` bitmaps (§3.2), not by a sentinel in the typed
/// value array.
final class PropNull extends PropValue {
  const PropNull();

  @override
  bool operator ==(Object other) => other is PropNull;
  @override
  int get hashCode => 0x501D4011;
  @override
  String toString() => 'PropNull()';
}

/// List of property values. Boundary-only; the v1 columnar property
/// store does not store list-valued properties.
final class PropList extends PropValue {
  final List<PropValue> values;
  const PropList(this.values);

  @override
  String toString() => 'PropList($values)';
}

/// Map of property values. Boundary-only; the v1 columnar property
/// store does not store map-valued properties.
final class PropMap extends PropValue {
  final Map<String, PropValue> values;
  const PropMap(this.values);

  @override
  String toString() => 'PropMap($values)';
}
