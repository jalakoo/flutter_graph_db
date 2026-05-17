/// Logical plan IR (plan §8 / §14 Phase 3B).
///
/// Sealed so future operators (`Sort`, `Limit`, `Aggregate`,
/// `VarLengthExpand`, etc.) land as additional cases the executor
/// must handle exhaustively. v1 ships the minimum read shape:
/// NodeScan → [Expand]* → [Filter] → Project [→ Distinct].
library;

import '../ast.dart';

sealed class LogicalPlan {
  const LogicalPlan();
}

/// Scans every node carrying [labelId] (if non-null) and binds the
/// vid to [alias]. `labelId == null` scans every visible node.
class NodeScan extends LogicalPlan {
  final String alias;
  final int? labelId;
  const NodeScan({required this.alias, required this.labelId});
}

/// For each incoming row, walks edges of [direction] (filtered by
/// [edgeTypeId] when set) from the vid bound to [fromAlias], and
/// emits one row per neighbour with [toAlias] (and [relAlias], when
/// non-null) added to the bindings.
class Expand extends LogicalPlan {
  final LogicalPlan source;
  final String fromAlias;
  final String toAlias;
  final String? relAlias;
  final int? edgeTypeId;
  final Direction direction;
  const Expand({
    required this.source,
    required this.fromAlias,
    required this.toAlias,
    required this.relAlias,
    required this.edgeTypeId,
    required this.direction,
  });
}

/// Filters incoming rows by [predicate] (evaluated against the row +
/// the engine state). Lowered from `WHERE` clauses and from inline
/// property filters (`(n {age: 30})`).
class Filter extends LogicalPlan {
  final LogicalPlan source;
  final Expression predicate;
  const Filter({required this.source, required this.predicate});
}

/// Final projection — evaluates each [items] expression and emits a
/// row keyed by the alias (or the expression's printed form when no
/// `AS alias` is given).
class Project extends LogicalPlan {
  final LogicalPlan source;
  final List<ReturnItem> items;

  /// The output column names (mirrors `items` length / order). The
  /// planner pre-computes these so the executor's first emission can
  /// publish the column header before the first row arrives.
  final List<String> columnNames;
  const Project({
    required this.source,
    required this.items,
    required this.columnNames,
  });
}

/// De-duplicates rows by all column values. Optional pass after
/// [Project] when the user wrote `RETURN DISTINCT ...`.
class Distinct extends LogicalPlan {
  final LogicalPlan source;
  const Distinct(this.source);
}

/// Aggregation operator (plan §8 / §14 Phase 3C). Groups incoming
/// rows by [groupExprs] (parallel arrays — same column name + same
/// expression) and accumulates [aggregates]. Emits one row per
/// distinct group.
class Aggregate extends LogicalPlan {
  final LogicalPlan source;

  /// Column name + expression for each non-aggregate RETURN item.
  /// Together these form the group key.
  final List<String> groupColumns;
  final List<Expression> groupExprs;

  /// Column name + aggregate spec for each aggregate RETURN item.
  final List<String> aggregateColumns;
  final List<AggregateExpr> aggregates;

  const Aggregate({
    required this.source,
    required this.groupColumns,
    required this.groupExprs,
    required this.aggregateColumns,
    required this.aggregates,
  });
}

/// Full materialised sort by [keys] (mixed ASC / DESC). v1 doesn't
/// special-case the top-k path — adding the heap when LIMIT is
/// present is a Phase 3C polish.
class Sort extends LogicalPlan {
  final LogicalPlan source;
  final List<SortKey> keys;
  const Sort({required this.source, required this.keys});
}

class SortKey {
  /// Expression evaluated against the row's bindings. May reference
  /// raw bindings (e.g. `n.age` where `n` is a `Vid`) or projected
  /// columns once `Sort` is inserted post-`Project`.
  final Expression expr;
  final bool ascending;
  const SortKey({required this.expr, required this.ascending});
}

/// Pagination — SKIP [skip] + LIMIT [limit]. Either may be `null`.
class Limit extends LogicalPlan {
  final LogicalPlan source;
  final int? skip;
  final int? limit;
  const Limit({
    required this.source,
    required this.skip,
    required this.limit,
  });
}

/// Variable-length expansion (plan §8 / §14 Phase 3D).
///
/// For each incoming row, walks edges of [direction] from
/// [fromAlias]'s binding via BFS up to [maxHops] (unbounded when
/// `null`); emits one row per reachable vid whose distance is at
/// least [minHops]. The intermediate path edges are **not** bound —
/// v1 does not project paths as values (plan §8 path-return-type is
/// a future field).
class VarLengthExpand extends LogicalPlan {
  final LogicalPlan source;
  final String fromAlias;
  final String toAlias;
  final int? edgeTypeId;
  final Direction direction;
  final int minHops;
  final int? maxHops;
  const VarLengthExpand({
    required this.source,
    required this.fromAlias,
    required this.toAlias,
    required this.edgeTypeId,
    required this.direction,
    required this.minHops,
    required this.maxHops,
  });
}
