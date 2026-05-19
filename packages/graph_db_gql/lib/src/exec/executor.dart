/// Push-based stream executor.
///
/// Each [LogicalPlan] case becomes a `Stream<ResultRow>` generator
/// that consumes its source stream and emits transformed rows. The
/// composition is purely sequential — no batching, no parallelism in
/// v1; row-batching is a later optimisation.
library;

import 'package:graph_db_core/graph_db_core.dart';

import '../ast.dart';
import '../plan/logical_plan.dart';
import 'expression_eval.dart';
import 'result_row.dart';

class GqlExecutor {
  final GraphDb db;
  GqlExecutor(this.db);

  /// Streams every result row from [plan]. [params] is consulted by
  /// `$param` expressions during evaluation.
  Stream<ResultRow> execute(
    LogicalPlan plan,
    Map<String, Object?> params,
  ) {
    final eval = ExpressionEvaluator(db, params);
    return _run(plan, eval);
  }

  /// Convenience — drains [execute] into a [QueryResult] and pairs it
  /// with the projected column names.
  Future<QueryResult> materialize(
    LogicalPlan plan,
    Map<String, Object?> params,
  ) async {
    final columns = _columnNames(plan);
    final rows = <ResultRow>[];
    await for (final row in execute(plan, params)) {
      rows.add(row);
    }
    return QueryResult(columns: columns, rows: rows);
  }

  List<String> _columnNames(LogicalPlan p) {
    switch (p) {
      case Project(:final columnNames):
        return columnNames;
      case Distinct(:final source):
        return _columnNames(source);
      case Sort(:final source):
        return _columnNames(source);
      case Limit(:final source):
        return _columnNames(source);
      default:
        throw StateError('top-level plan must end in Project');
    }
  }

  Stream<ResultRow> _run(LogicalPlan plan, ExpressionEvaluator eval) async* {
    switch (plan) {
      case NodeScan():
        yield* _runScan(plan);
      case Expand():
        yield* _runExpand(plan, eval);
      case Filter():
        await for (final row in _run(plan.source, eval)) {
          final v = eval.eval(plan.predicate, row);
          if (v == true) yield row;
        }
      case Project():
        await for (final row in _run(plan.source, eval)) {
          final out = <String, Object?>{};
          for (var i = 0; i < plan.items.length; i++) {
            out[plan.columnNames[i]] =
                eval.eval(plan.items[i].expr, row);
          }
          yield ResultRow(out);
        }
      case Distinct():
        final seen = <String>{};
        await for (final row in _run(plan.source, eval)) {
          // Cheap canonical key — values' toString in column order.
          final key = row.values.values
              .map((v) => v == null ? '∅' : v.toString())
              .join('');
          if (seen.add(key)) yield row;
        }
      case Aggregate():
        yield* _runAggregate(plan, eval);
      case Sort():
        yield* _runSort(plan, eval);
      case Limit():
        yield* _runLimit(plan, eval);
      case VarLengthExpand():
        yield* _runVarLengthExpand(plan, eval);
    }
  }

  Stream<ResultRow> _runVarLengthExpand(
    VarLengthExpand op,
    ExpressionEvaluator eval,
  ) async* {
    await for (final row in _run(op.source, eval)) {
      final fromBinding = row.values[op.fromAlias];
      if (fromBinding is! Vid) continue;
      // BFS — emit a row per (depth, neighbour) within bounds.
      // We track visited per-source to avoid cycles inflating the
      // result count (Cypher semantics — no repeated nodes in the path).
      final visited = <int>{fromBinding.value};
      var frontier = <int>[fromBinding.value];
      var depth = 0;
      while (frontier.isNotEmpty &&
          (op.maxHops == null || depth < op.maxHops!)) {
        final next = <int>[];
        for (final v in frontier) {
          final neighbours = <int>[];
          if (op.direction == Direction.outgoing ||
              op.direction == Direction.undirected) {
            db.state.forEachOutEdge(Vid(v), (eid, dst, et) {
              if (op.edgeTypeId != null && et != op.edgeTypeId) return;
              neighbours.add(dst.value);
            });
          }
          if (op.direction == Direction.incoming ||
              op.direction == Direction.undirected) {
            db.state.forEachInEdge(Vid(v), (eid, src, et) {
              if (op.edgeTypeId != null && et != op.edgeTypeId) return;
              neighbours.add(src.value);
            });
          }
          for (final n in neighbours) {
            if (visited.add(n)) {
              next.add(n);
            }
          }
        }
        depth++;
        for (final n in next) {
          if (depth >= op.minHops) {
            final out = Map<String, Object?>.from(row.values);
            out[op.toAlias] = Vid(n);
            yield ResultRow(out);
          }
        }
        frontier = next;
      }
    }
  }

  Stream<ResultRow> _runScan(NodeScan scan) async* {
    final state = db.state;
    final labelIds = scan.labelIds;
    if (labelIds == null || labelIds.isEmpty) {
      // Full scan — every visible node.
      for (var v = 0; v < state.csr.nodeCount; v++) {
        if (!state.overlay.deletedNodes.contains(v)) {
          yield ResultRow({scan.alias: Vid(v)});
        }
      }
      for (final v in state.overlay.addedNodes.keys) {
        if (!state.overlay.deletedNodes.contains(v)) {
          yield ResultRow({scan.alias: Vid(v)});
        }
      }
      return;
    }

    // Multi-label AND scan. Pick the smallest CSR label index as the
    // seed for the intersection, then filter the rest via
    // `state.hasLabelEffective`. Also merge in overlay-added /
    // label-override vids whose effective sets contain every label.
    var seedLabel = labelIds.first;
    var seedSize = state.csr.labelIndex[seedLabel]?.length ?? 0;
    for (var i = 1; i < labelIds.length; i++) {
      final size = state.csr.labelIndex[labelIds[i]]?.length ?? 0;
      if (size < seedSize) {
        seedLabel = labelIds[i];
        seedSize = size;
      }
    }
    final yielded = <int>{};
    final base = state.csr.labelIndex[seedLabel];
    if (base != null) {
      outer:
      for (final v in base) {
        if (state.overlay.deletedNodes.contains(v)) continue;
        // Honour overlay label-override — when present, defer to it
        // entirely (it may have removed [seedLabel]).
        final override = state.overlay.labelOverride[v];
        if (override != null) {
          for (final l in labelIds) {
            if (!override.contains(l)) continue outer;
          }
        } else {
          for (final l in labelIds) {
            if (l == seedLabel) continue; // already known
            if (!state.csr.hasLabel(v, l)) continue outer;
          }
        }
        yielded.add(v);
        yield ResultRow({scan.alias: Vid(v)});
      }
    }
    // Overlay-added nodes whose set contains every required label.
    outerAdded:
    for (final entry in state.overlay.addedNodes.entries) {
      final vid = entry.key;
      if (state.overlay.deletedNodes.contains(vid)) continue;
      if (yielded.contains(vid)) continue;
      for (final l in labelIds) {
        if (!entry.value.labelIds.contains(l)) continue outerAdded;
      }
      yielded.add(vid);
      yield ResultRow({scan.alias: Vid(vid)});
    }
    // Pre-existing CSR vids that *gained* the full label set via a
    // label-override (and weren't already yielded by the seed scan).
    outerOv:
    for (final entry in state.overlay.labelOverride.entries) {
      final vid = entry.key;
      if (state.overlay.deletedNodes.contains(vid)) continue;
      if (yielded.contains(vid)) continue;
      for (final l in labelIds) {
        if (!entry.value.contains(l)) continue outerOv;
      }
      yielded.add(vid);
      yield ResultRow({scan.alias: Vid(vid)});
    }
  }

  Stream<ResultRow> _runExpand(
    Expand expand,
    ExpressionEvaluator eval,
  ) async* {
    await for (final row in _run(expand.source, eval)) {
      final fromBinding = row.values[expand.fromAlias];
      if (fromBinding is! Vid) {
        // shouldn't happen in well-formed plans
        continue;
      }
      // Collect neighbours into a small list — callback-based forEach
      // doesn't compose with `async*`.
      final neighbours = <_Neighbour>[];
      final from = fromBinding;
      if (expand.direction == Direction.outgoing ||
          expand.direction == Direction.undirected) {
        db.state.forEachOutEdge(from, (eid, dst, et) {
          neighbours.add(_Neighbour(eid: eid, vid: dst, edgeType: et));
        });
      }
      if (expand.direction == Direction.incoming ||
          expand.direction == Direction.undirected) {
        db.state.forEachInEdge(from, (eid, src, et) {
          neighbours.add(_Neighbour(eid: eid, vid: src, edgeType: et));
        });
      }
      for (final n in neighbours) {
        if (expand.edgeTypeId != null && n.edgeType != expand.edgeTypeId) {
          continue;
        }
        final newValues = Map<String, Object?>.from(row.values);
        newValues[expand.toAlias] = n.vid;
        if (expand.relAlias != null) {
          newValues[expand.relAlias!] = n.eid;
        }
        yield ResultRow(newValues);
      }
    }
  }

  Stream<ResultRow> _runAggregate(
    Aggregate agg,
    ExpressionEvaluator eval,
  ) async* {
    final groups = <String, _AggGroup>{};
    await for (final row in _run(agg.source, eval)) {
      final keyValues = [
        for (final ge in agg.groupExprs) eval.eval(ge, row),
      ];
      final key =
          keyValues.map((v) => v == null ? '∅' : v.toString()).join('|');
      var group = groups[key];
      if (group == null) {
        group = _AggGroup(
          keyValues: keyValues,
          accumulators: [
            for (final a in agg.aggregates) _newAccumulator(a.fn),
          ],
        );
        groups[key] = group;
      }
      for (var i = 0; i < agg.aggregates.length; i++) {
        final aggExpr = agg.aggregates[i];
        final value = aggExpr.argument == null
            ? null
            : eval.eval(aggExpr.argument!, row);
        // COUNT(*) increments per row even though value is null — pass
        // a non-null sentinel via the accumulator's special-case.
        if (aggExpr.fn == AggregateFn.count && aggExpr.argument == null) {
          group.accumulators[i].add(1);
        } else {
          group.accumulators[i].add(value);
        }
      }
    }
    for (final group in groups.values) {
      final out = <String, Object?>{};
      for (var i = 0; i < agg.groupColumns.length; i++) {
        out[agg.groupColumns[i]] = group.keyValues[i];
      }
      for (var i = 0; i < agg.aggregateColumns.length; i++) {
        out[agg.aggregateColumns[i]] = group.accumulators[i].result();
      }
      yield ResultRow(out);
    }
    // Single empty-input row when there are no group keys (a single
    // aggregate over an empty input) — emit accumulator identity.
    if (groups.isEmpty && agg.groupColumns.isEmpty) {
      final out = <String, Object?>{};
      for (var i = 0; i < agg.aggregateColumns.length; i++) {
        final acc = _newAccumulator(agg.aggregates[i].fn);
        out[agg.aggregateColumns[i]] = acc.result();
      }
      yield ResultRow(out);
    }
  }

  Stream<ResultRow> _runSort(Sort sort, ExpressionEvaluator eval) async* {
    // Materialise + decorate each row with the sort-key values
    // up-front so the comparator never re-evaluates.
    final decorated = <(ResultRow, List<Object?>)>[];
    await for (final row in _run(sort.source, eval)) {
      final keys = [
        for (final k in sort.keys) _safeEval(k.expr, row, eval),
      ];
      decorated.add((row, keys));
    }
    decorated.sort((a, b) {
      for (var i = 0; i < sort.keys.length; i++) {
        final c = _compareForSort(a.$2[i], b.$2[i]);
        if (c != 0) return sort.keys[i].ascending ? c : -c;
      }
      return 0;
    });
    for (final entry in decorated) {
      yield entry.$1;
    }
  }

  Object? _safeEval(
    Expression e,
    ResultRow row,
    ExpressionEvaluator eval,
  ) {
    try {
      return eval.eval(e, row);
    } on EvalException {
      // ORDER BY may reference a projected alias that doesn't exist
      // in raw form; treat unresolvable as null (sorts to one end).
      return null;
    }
  }

  int _compareForSort(Object? a, Object? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
    return a.toString().compareTo(b.toString());
  }

  Stream<ResultRow> _runLimit(Limit limit, ExpressionEvaluator eval) async* {
    var skipped = 0;
    var emitted = 0;
    await for (final row in _run(limit.source, eval)) {
      if (limit.skip != null && skipped < limit.skip!) {
        skipped++;
        continue;
      }
      if (limit.limit != null && emitted >= limit.limit!) break;
      emitted++;
      yield row;
    }
  }

  _Accumulator _newAccumulator(AggregateFn fn) {
    switch (fn) {
      case AggregateFn.count:
        return _CountAcc();
      case AggregateFn.sum:
        return _SumAcc();
      case AggregateFn.avg:
        return _AvgAcc();
      case AggregateFn.min:
        return _MinAcc();
      case AggregateFn.max:
        return _MaxAcc();
      case AggregateFn.collect:
        return _CollectAcc();
    }
  }
}

class _Neighbour {
  final Eid eid;
  final Vid vid;
  final int edgeType;
  const _Neighbour({
    required this.eid,
    required this.vid,
    required this.edgeType,
  });
}

class _AggGroup {
  final List<Object?> keyValues;
  final List<_Accumulator> accumulators;
  _AggGroup({required this.keyValues, required this.accumulators});
}

abstract class _Accumulator {
  void add(Object? value);
  Object? result();
}

class _CountAcc extends _Accumulator {
  int _n = 0;
  @override
  void add(Object? value) {
    // COUNT(*) increments unconditionally; COUNT(expr) skips nulls.
    if (value == null) return;
    _n++;
  }
  @override
  Object? result() => _n;
}

class _SumAcc extends _Accumulator {
  num _sum = 0;
  bool _anyDouble = false;
  @override
  void add(Object? value) {
    if (value == null) return;
    if (value is! num) {
      throw EvalException('SUM expects numbers, got ${value.runtimeType}');
    }
    if (value is double) _anyDouble = true;
    _sum += value;
  }
  @override
  Object? result() => _anyDouble ? _sum.toDouble() : _sum.toInt();
}

class _AvgAcc extends _Accumulator {
  num _sum = 0;
  int _n = 0;
  @override
  void add(Object? value) {
    if (value == null) return;
    if (value is! num) {
      throw EvalException('AVG expects numbers, got ${value.runtimeType}');
    }
    _sum += value;
    _n++;
  }
  @override
  Object? result() => _n == 0 ? null : _sum / _n;
}

class _MinAcc extends _Accumulator {
  Object? _best;
  @override
  void add(Object? value) {
    if (value == null) return;
    if (_best == null) {
      _best = value;
      return;
    }
    if (_compare(value, _best!) < 0) _best = value;
  }
  @override
  Object? result() => _best;
}

class _MaxAcc extends _Accumulator {
  Object? _best;
  @override
  void add(Object? value) {
    if (value == null) return;
    if (_best == null) {
      _best = value;
      return;
    }
    if (_compare(value, _best!) > 0) _best = value;
  }
  @override
  Object? result() => _best;
}

class _CollectAcc extends _Accumulator {
  final List<Object?> _items = [];
  @override
  void add(Object? value) {
    if (value == null) return;
    _items.add(value);
  }
  @override
  Object? result() => List<Object?>.unmodifiable(_items);
}

int _compare(Object a, Object b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
  throw EvalException(
      'cannot order ${a.runtimeType} against ${b.runtimeType}');
}
