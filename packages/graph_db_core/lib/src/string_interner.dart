/// What kind of string is being interned (plan §3.5, §6.4).
///
/// Each kind has its own monotonic id space — a label id and a property
/// key id with the same numeric value refer to different things.
enum StringKind { label, edgeType, propKey }

class _Space {
  final Map<String, int> _toId = {};
  final List<String> _byId = [];

  int intern(String s) {
    final existing = _toId[s];
    if (existing != null) return existing;
    final id = _byId.length;
    _byId.add(s);
    _toId[s] = id;
    return id;
  }

  String? get(int id) => (id >= 0 && id < _byId.length) ? _byId[id] : null;

  int get count => _byId.length;
}

/// Global string-table for labels, edge types, property keys
/// (plan §3.5). Monotonic per kind; never reused.
///
/// Property *values* of type `String` are NOT interned here — unbounded
/// cardinality. (The columnar store may intern low-cardinality string
/// columns into a per-column dictionary; that is a separate concern.)
class StringInterner {
  final _Space _labels = _Space();
  final _Space _edgeTypes = _Space();
  final _Space _propKeys = _Space();

  int internLabel(String s) => _labels.intern(s);
  int internEdgeType(String s) => _edgeTypes.intern(s);
  int internPropKey(String s) => _propKeys.intern(s);

  String? labelOf(int id) => _labels.get(id);
  String? edgeTypeOf(int id) => _edgeTypes.get(id);
  String? propKeyOf(int id) => _propKeys.get(id);

  int get labelCount => _labels.count;
  int get edgeTypeCount => _edgeTypes.count;
  int get propKeyCount => _propKeys.count;
}
