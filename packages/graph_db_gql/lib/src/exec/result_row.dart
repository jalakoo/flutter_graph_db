/// One row of query output (plan §8 / §14 Phase 3B).
///
/// Bindings keyed by alias — Vids and Eids during the operator chain,
/// projected values after [Project]. `Map<String, Object?>` keeps the
/// hot-path allocation predictable; future sub-phases can swap for a
/// columnar shape if the bench warrants it.
library;

class ResultRow {
  final Map<String, Object?> values;
  const ResultRow(this.values);

  @override
  String toString() => 'ResultRow($values)';
}

/// Materialised, queryable shape returned by `GraphDb.executeQuery`.
class QueryResult {
  final List<String> columns;
  final List<ResultRow> rows;
  const QueryResult({required this.columns, required this.rows});

  int get length => rows.length;
  bool get isEmpty => rows.isEmpty;
  bool get isNotEmpty => rows.isNotEmpty;
}
