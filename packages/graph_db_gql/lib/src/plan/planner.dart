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
import '../diagnostics/planner_diagnostic.dart';
import 'logical_plan.dart';
import 'write_plan.dart';

class PlannerException implements Exception {
  final String message;
  PlannerException(this.message);
  @override
  String toString() => 'PlannerException: $message';
}

class GqlPlanner {
  final GraphReadView view;

  /// Optional non-fatal diagnostic sink. `null` ⇒ diagnostics are
  /// silently dropped (the planner still runs).
  final PlannerDiagnosticListener? onDiagnostic;

  GqlPlanner(this.view, {this.onDiagnostic});

  void _emit(PlannerDiagnostic d) {
    final l = onDiagnostic;
    if (l != null) l(d);
  }

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

  /// Plans a *write* statement into a [WritePlan]. Mirrors [plan] for the
  /// mutating path: `executeQuery` dispatches reads → [plan] + `GqlExecutor`,
  /// writes → [planWrite] + `GqlWriteExecutor`. A4.1 handles `CREATE`;
  /// MERGE / MATCH…SET land in A4.2 / A4.3.
  WritePlan planWrite(GqlStatement stmt) {
    switch (stmt) {
      case CreateStatement():
        return CreatePlan(
          pattern: stmt.pattern,
          returnClause: stmt.returnClause,
        );
      case MergeStatement():
        return MergePlan(
          node: stmt.pattern,
          returnClause: stmt.returnClause,
        );
      case MatchStatement():
        // MATCH … SET/DELETE. Plan the match twice, **once**: a passthrough
        // binding plan (alias → Vid/Eid handles for the mutation step) and,
        // when the statement has a RETURN, a projection plan over the
        // post-mutation state (carrying ORDER BY / SKIP / LIMIT).
        final bindingPlan = plan(MatchStatement(
          patterns: stmt.patterns,
          where: stmt.where,
          returnClause: ReturnClause(
            distinct: false,
            items: _bindingsAsReturnItems(stmt.patterns),
          ),
        ));
        final projectionPlan = stmt.returnClause == null
            ? null
            : plan(MatchStatement(
                patterns: stmt.patterns,
                where: stmt.where,
                returnClause: stmt.returnClause,
                orderBy: stmt.orderBy,
                skip: stmt.skip,
                limit: stmt.limit,
              ));
        return MutatePlan(
          bindingPlan: bindingPlan,
          mutations: stmt.mutations!,
          projectionPlan: projectionPlan,
        );
    }
  }

  /// Synthesises a passthrough RETURN of every aliased binding in
  /// [patterns] — used by [planWrite] so a MATCH…SET's binding plan yields
  /// Vid/Eid handles rather than projected property values.
  List<ReturnItem> _bindingsAsReturnItems(List<PatternPart> patterns) {
    final out = <ReturnItem>[];
    for (final p in patterns) {
      if (p.start.alias != null) {
        out.add(ReturnItem(
          expr: IdentifierExpr(p.start.alias!),
          alias: p.start.alias,
        ));
      }
      for (final n in p.nodes) {
        if (n.alias != null) {
          out.add(ReturnItem(expr: IdentifierExpr(n.alias!), alias: n.alias));
        }
      }
      for (final r in p.relationships) {
        if (r.alias != null) {
          out.add(ReturnItem(expr: IdentifierExpr(r.alias!), alias: r.alias));
        }
      }
    }
    return out;
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

    // Collect node-typed aliases so the `node.label` deprecation
    // diagnostic can fire when they're accessed via `.label`.
    final nodeAliases = <String>{};
    if (start.alias != null) nodeAliases.add(start.alias!);
    for (final n in part.nodes) {
      if (n.alias != null) nodeAliases.add(n.alias!);
    }
    if (m.where != null) {
      _scanForDeprecatedLabelAccess(m.where!, nodeAliases);
    }
    if (m.returnClause != null) {
      for (final item in m.returnClause!.items) {
        _scanForDeprecatedLabelAccess(item.expr, nodeAliases);
      }
    }
    if (start.alias == null) {
      throw PlannerException(
        'starting node pattern must be aliased — e.g. (n:Label)',
      );
    }
    LogicalPlan plan = NodeScan(
      alias: start.alias!,
      labelIds: _resolveLabels(start.labels),
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

  /// Walks [e] and fires a `PlannerDiagnostic.warning` for every
  /// `<nodeAlias>.label` access — deprecated in the multi-label
  /// rollout (§19.9). A node carries a *set* of labels now; the old
  /// scalar `.label` access still parses but compares like
  /// `[List<String>] == 'Person'` which silently evaluates to false.
  /// The diagnostic makes the break loud at plan time. Suggested
  /// rewrite: `labels(<alias>)` (returns a sorted list) or
  /// `'Person' IN labels(<alias>)` for membership tests.
  void _scanForDeprecatedLabelAccess(Expression e, Set<String> nodeAliases) {
    switch (e) {
      case PropertyAccessExpr(:final target, :final key):
        if (key == 'label' &&
            target is IdentifierExpr &&
            nodeAliases.contains(target.name)) {
          _emit(PlannerDiagnostic(
            severity: PlannerDiagnosticSeverity.warning,
            message:
                'access of `${target.name}.label` is deprecated — nodes '
                'now carry a set of labels (multi-label rollout)',
            hint: 'use `labels(${target.name})` (sorted list) or '
                "`'Person' IN labels(${target.name})` for membership",
          ));
        }
        _scanForDeprecatedLabelAccess(target, nodeAliases);
      case BinaryOpExpr(:final left, :final right):
        _scanForDeprecatedLabelAccess(left, nodeAliases);
        _scanForDeprecatedLabelAccess(right, nodeAliases);
      case UnaryOpExpr(:final operand):
        _scanForDeprecatedLabelAccess(operand, nodeAliases);
      case FunctionCallExpr(:final arguments):
        for (final a in arguments) {
          _scanForDeprecatedLabelAccess(a, nodeAliases);
        }
      case AggregateExpr(:final argument):
        if (argument != null) {
          _scanForDeprecatedLabelAccess(argument, nodeAliases);
        }
      case IdentifierExpr():
      case LiteralExpr():
      case ParameterExpr():
        return;
    }
  }

  /// Resolves every label name in [labels] to its interned id.
  /// `(:A:B)` patterns become a list with AND-semantics at execution
  /// time. Returns `null` for an empty list (full scan).
  List<int>? _resolveLabels(List<String> labels) {
    if (labels.isEmpty) return null;
    final out = <int>[];
    for (final name in labels) {
      final id = view.labelId(name);
      if (id == null) {
        throw PlannerException(
          'unknown label "$name" — intern it first or check the spelling',
        );
      }
      out.add(id);
    }
    out.sort(); // deterministic intersection order
    return out;
  }

  int? _resolveEdgeType(List<String> types) {
    if (types.isEmpty) return null;
    final id = view.edgeTypeId(types.first);
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

  /// Synthesises a predicate for `(:Label[:Label2...])` constraints
  /// attached to expanded nodes — the executor would otherwise have
  /// no way to filter on label after the Expand. Each label becomes a
  /// `labelId IN labels(alias)` test (sugared as
  /// `__label_contains == labelId`), AND-combined.
  Expression _labelMatchPredicate(String alias, List<String> labels) {
    Expression? combined;
    for (final name in labels) {
      final labelId = view.labelId(name);
      if (labelId == null) {
        throw PlannerException(
          'unknown label "$name" on expanded node — intern it first',
        );
      }
      // `__label_contains(<alias>) == labelId` — the evaluator returns
      // true iff the alias's vid effectively carries `labelId`.
      final pred = BinaryOpExpr(
        BinaryOp.eq,
        PropertyAccessExpr(
          IdentifierExpr(alias),
          _internalLabelContainsKey(labelId),
        ),
        LiteralExpr(true),
      );
      combined = combined == null
          ? pred
          : BinaryOpExpr(BinaryOp.and, combined, pred);
    }
    return combined!;
  }

  /// Encodes a "vid carries this label-id?" probe inside the magic
  /// `__label_contains:<id>` sentinel key. Cheap stringly-typed
  /// trick avoids extending the `Expression` AST in PR 3.
  String _internalLabelContainsKey(int labelId) =>
      '$kInternalLabelContainsKeyPrefix$labelId';

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
/// node's labels list" — multi-label rollout PR 3, returns a sorted
/// `List<String>` (per §19.5 of the multi-label plan).
const String kInternalLabelKey = ' __label';

/// Sentinel-key *prefix* for the `__label_contains:<labelId>` probe.
/// `_labelMatchPredicate` emits `PropertyAccessExpr` with this prefix
/// + an interned label id; the evaluator recognises the prefix and
/// returns `true` iff the bound vid effectively carries that label.
const String kInternalLabelContainsKeyPrefix = ' __label_contains:';
