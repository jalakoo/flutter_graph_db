/// Rule-based planner — `MatchStatement` → [LogicalPlan]
///.
///
/// v1: single [PatternPart] only. Multi-pattern (comma-separated)
/// requires a Cartesian / join operator scheduled for a later
/// sub-phase. The planner consults the engine's [StringInterner] to
/// resolve label / type / property names to interned ids up front so
/// the executor only deals with numbers on the hot path.
library;

import 'package:graph_db_core/graph_db_core.dart';

import '../ast.dart';
import 'logical_plan.dart';

class PlannerException implements Exception {
  final String message;
  PlannerException(this.message);
  @override
  String toString() => 'PlannerException: $message';
}

class GqlPlanner {
  final GraphDb db;
  GqlPlanner(this.db);

  LogicalPlan plan(GqlStatement stmt) {
    switch (stmt) {
      case MatchStatement():
        return _planMatch(stmt);
      case CreateStatement():
      case MergeStatement():
        throw PlannerException(
          'Write statements execute via the write path, not the '
          'read planner — pass through `executeQuery`',
        );
    }
  }

  LogicalPlan _planMatch(MatchStatement m) {
    if (m.patterns.length != 1) {
      throw PlannerException(
        'multi-pattern MATCH (comma-separated) lands in a later '
        'the future work sub-phase',
      );
    }
    final part = m.patterns.single;
    final start = part.start;
    if (start.alias == null) {
      throw PlannerException(
        'starting node pattern must be aliased — e.g. (n:Label)',
      );
    }
    LogicalPlan plan = NodeScan(
      alias: start.alias!,
      labelId: _resolveLabel(start.labels),
    );
    // Inline property predicates on the start node.
    plan = _attachInlineProps(plan, start.alias!, start.properties);

    for (var i = 0; i < part.relationships.length; i++) {
      final rel = part.relationships[i];
      final to = part.nodes[i];
      if (to.alias == null) {
        throw PlannerException(
          'expanded node pattern must be aliased (got '
          '${rel.alias ?? "anonymous"})',
        );
      }
      if (rel.isVarLength) {
        if (rel.alias != null) {
          throw PlannerException(
            'variable-length relationships cannot bind a single alias '
            '(use Path return type once it lands)',
          );
        }
        plan = VarLengthExpand(
          source: plan,
          fromAlias: i == 0 ? start.alias! : part.nodes[i - 1].alias!,
          toAlias: to.alias!,
          edgeTypeId: _resolveEdgeType(rel.types),
          direction: rel.direction,
          minHops: rel.minHops ?? 1,
          maxHops: rel.maxHops,
        );
      } else {
        plan = Expand(
          source: plan,
          fromAlias: i == 0 ? start.alias! : part.nodes[i - 1].alias!,
          toAlias: to.alias!,
          relAlias: rel.alias,
          edgeTypeId: _resolveEdgeType(rel.types),
          direction: rel.direction,
        );
      }
      // Label filter on the expanded node, via WHERE-equivalent
      // predicate.
      if (to.labels.isNotEmpty) {
        plan = Filter(
          source: plan,
          predicate: _labelMatchPredicate(to.alias!, to.labels),
        );
      }
      plan = _attachInlineProps(plan, to.alias!, to.properties);
    }

    if (m.where != null) {
      plan = Filter(source: plan, predicate: m.where!);
    }

    // Write-only MATCH (no RETURN) → synthesise an empty projection
    // so the executor still produces a uniform shape. The mutation
    // path drives state changes; the result is empty.
    final returnClause = m.returnClause ??
        const ReturnClause(distinct: false, items: []);

    final columnNames = [
      for (var i = 0; i < returnClause.items.length; i++)
        returnClause.items[i].alias ??
            _exprAsColumnName(returnClause.items[i].expr, i),
    ];

    // Aggregation lowering: if ANY RETURN item is or contains an
    // AggregateExpr, split items into group keys + aggregate
    // accumulators and insert an Aggregate op before Project.
    final hasAggregate =
        returnClause.items.any((item) => _containsAggregate(item.expr));
    if (hasAggregate) {
      final groupColumns = <String>[];
      final groupExprs = <Expression>[];
      final aggregateColumns = <String>[];
      final aggregates = <AggregateExpr>[];
      for (var i = 0; i < returnClause.items.length; i++) {
        final item = returnClause.items[i];
        if (item.expr is AggregateExpr) {
          aggregateColumns.add(columnNames[i]);
          aggregates.add(item.expr as AggregateExpr);
        } else if (_containsAggregate(item.expr)) {
          throw PlannerException(
            'aggregate functions must appear as top-level RETURN items '
            'in v1 (e.g. RETURN n.age, COUNT(*)). Nested arithmetic '
            'over aggregates lands in a later phase.',
          );
        } else {
          groupColumns.add(columnNames[i]);
          groupExprs.add(item.expr);
        }
      }
      plan = Aggregate(
        source: plan,
        groupColumns: groupColumns,
        groupExprs: groupExprs,
        aggregateColumns: aggregateColumns,
        aggregates: aggregates,
      );
      // The Aggregate op emits rows whose columns are already the
      // final shape — Project becomes a pass-through that just enforces
      // the declared column order.
      final passthroughItems = [
        for (final name in columnNames)
          ReturnItem(expr: IdentifierExpr(name), alias: name),
      ];
      plan = Project(
        source: plan,
        items: passthroughItems,
        columnNames: columnNames,
      );
    } else {
      plan = Project(
        source: plan,
        items: returnClause.items,
        columnNames: columnNames,
      );
    }

    // ORDER BY → Sort. Inserted BEFORE Project so the sort-key
    // expression can reference raw bindings (`n.age`) even when
    // the projection only returns `n.name`. For aggregated queries
    // Sort still sees the post-Aggregate row (which has the named
    // group columns + aggregate columns), so column-name ORDER BY
    // works too.
    if (m.orderBy != null) {
      // Re-find the projection in the plan chain and insert Sort
      // immediately before it.
      plan = _insertSortBeforeProject(
        plan,
        [
          for (final item in m.orderBy!)
            SortKey(expr: item.expr, ascending: item.ascending),
        ],
      );
    }

    if (returnClause.distinct) {
      plan = Distinct(plan);
    }

    if (m.skip != null || m.limit != null) {
      plan = Limit(source: plan, skip: m.skip, limit: m.limit);
    }
    return plan;
  }

  /// Walks [plan] from the outermost op, finds the first [Project],
  /// and wraps that Project's source with a [Sort]. The Project then
  /// reads from the sorted stream, preserving order through to the
  /// caller.
  LogicalPlan _insertSortBeforeProject(
    LogicalPlan plan,
    List<SortKey> keys,
  ) {
    if (plan is Project) {
      final sorted = Sort(source: plan.source, keys: keys);
      return Project(
        source: sorted,
        items: plan.items,
        columnNames: plan.columnNames,
      );
    }
    // No Project found — wrap whole plan in Sort (should not happen
    // for well-formed MATCH-RETURN statements).
    return Sort(source: plan, keys: keys);
  }

  /// Recursively checks whether [e] contains an [AggregateExpr].
  bool _containsAggregate(Expression e) {
    switch (e) {
      case AggregateExpr():
        return true;
      case LiteralExpr():
      case IdentifierExpr():
      case ParameterExpr():
        return false;
      case PropertyAccessExpr(:final target):
        return _containsAggregate(target);
      case BinaryOpExpr(:final left, :final right):
        return _containsAggregate(left) || _containsAggregate(right);
      case UnaryOpExpr(:final operand):
        return _containsAggregate(operand);
      case FunctionCallExpr(:final arguments):
        for (final a in arguments) {
          if (_containsAggregate(a)) return true;
        }
        return false;
    }
  }

  int? _resolveLabel(List<String> labels) {
    if (labels.isEmpty) return null;
    // v1 single-label storage — first label wins.
    final id = db.state.strings.labelIdOf(labels.first);
    if (id == null) {
      throw PlannerException(
        'unknown label "${labels.first}" — intern it first or check '
        'the spelling',
      );
    }
    return id;
  }

  int? _resolveEdgeType(List<String> types) {
    if (types.isEmpty) return null;
    final id = db.state.strings.edgeTypeIdOf(types.first);
    if (id == null) {
      throw PlannerException(
        'unknown edge type "${types.first}"',
      );
    }
    return id;
  }

  LogicalPlan _attachInlineProps(
    LogicalPlan source,
    String alias,
    Map<String, Expression> props,
  ) {
    if (props.isEmpty) return source;
    Expression? combined;
    for (final entry in props.entries) {
      final pred = BinaryOpExpr(
        BinaryOp.eq,
        PropertyAccessExpr(IdentifierExpr(alias), entry.key),
        entry.value,
      );
      if (combined == null) {
        combined = pred;
      } else {
        combined = BinaryOpExpr(BinaryOp.and, combined, pred);
      }
    }
    return Filter(source: source, predicate: combined!);
  }

  /// Synthesises a predicate for `(:Label)` constraints attached to
  /// expanded nodes — the executor would otherwise have no way to
  /// filter on label after the Expand. Implemented as a pseudo
  /// property `__label` accessed via a magic key the evaluator
  /// recognises.
  Expression _labelMatchPredicate(String alias, List<String> labels) {
    // v1 single-label — the first label is enforced; secondary labels
    // accepted by the parser are ignored.
    final labelId = db.state.strings.labelIdOf(labels.first);
    if (labelId == null) {
      throw PlannerException(
        'unknown label "${labels.first}" on expanded node — intern '
        'it first',
      );
    }
    return BinaryOpExpr(
      BinaryOp.eq,
      PropertyAccessExpr(IdentifierExpr(alias), _kInternalLabelKey),
      LiteralExpr(labelId),
    );
  }

  String _exprAsColumnName(Expression e, int index) {
    switch (e) {
      case IdentifierExpr(:final name):
        return name;
      case PropertyAccessExpr(:final target, :final key):
        if (target is IdentifierExpr) return '${target.name}.$key';
        return key;
      case AggregateExpr(:final fn, :final argument):
        final argStr = argument == null ? '*' : _exprToShortString(argument);
        return '${fn.name.toUpperCase()}($argStr)';
      default:
        return 'col$index';
    }
  }

  String _exprToShortString(Expression e) {
    switch (e) {
      case IdentifierExpr(:final name):
        return name;
      case PropertyAccessExpr(:final target, :final key):
        if (target is IdentifierExpr) return '${target.name}.$key';
        return key;
      case LiteralExpr(:final value):
        return '$value';
      default:
        return '?';
    }
  }
}

/// Magic property key recognised by [ExpressionEvaluator] as "the
/// node's label id". Used by the planner to lower label constraints
/// on expanded nodes into uniform predicate evaluation.
const String _kInternalLabelKey = ' __label';

/// Public re-export so the evaluator can see the same sentinel.
const String kInternalLabelKey = _kInternalLabelKey;
