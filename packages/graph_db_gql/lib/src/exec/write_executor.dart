/// Transaction-bound executor for [WritePlan]s (plan A4).
///
/// The mutating sibling of the read [GqlExecutor] — one [GqlPlanner] feeds
/// both. Writes need a real transaction + interning, so this holds a
/// [GraphDb] (the read executor's [GraphReadView] firewall doesn't apply —
/// writes are engine-coupled by nature). Embedded read sub-plans (a
/// MERGE's match, a MATCH…SET's pattern) run through a [GqlExecutor] over
/// `db.readView`.
library;

import 'package:graph_db_core/graph_db_core.dart';

import '../ast.dart';
import '../plan/planner.dart' show GqlPlanner, PlannerException;
import '../plan/write_plan.dart';
import 'executor.dart';
import 'expression_eval.dart';
import 'result_row.dart';

class GqlWriteExecutor {
  final GraphDb db;
  GqlWriteExecutor(this.db);

  /// Runs [plan] in one transaction; returns the projected rows (an empty
  /// [QueryResult] when the statement carries no RETURN).
  Future<QueryResult> execute(WritePlan plan, Map<String, Object?> params) {
    switch (plan) {
      case CreatePlan():
        return _runCreate(plan, params);
      case MergePlan():
        return _runMerge(plan, params);
      case MutatePlan():
        return _runMutate(plan, params);
    }
  }

  /// MATCH … SET/DELETE — drains the binding rows (pre-mutation), applies
  /// the mutations in one txn, then projects the post-mutation state via
  /// the carried projection plan (both plans were built once by the
  /// planner). The eval reads through `db.readView` (unguarded — OQ6), so
  /// a `SET n.x = n.y + 1` can read while writes are buffered.
  Future<QueryResult> _runMutate(
    MutatePlan plan,
    Map<String, Object?> params,
  ) async {
    final eval = ExpressionEvaluator(db.readView, params);
    final reader = GqlExecutor(db.readView);
    final preRows = <ResultRow>[];
    await for (final row in reader.execute(plan.bindingPlan, params)) {
      preRows.add(row);
    }
    await db.runTransaction((txn) {
      for (final row in preRows) {
        for (final clause in plan.mutations) {
          _applyMutation(clause, row, txn, eval);
        }
      }
    }, durability: Durability.group);
    final projectionPlan = plan.projectionPlan;
    if (projectionPlan == null) return const QueryResult(columns: [], rows: []);
    return reader.materialize(projectionPlan, params);
  }

  void _applyMutation(
    MutatingClause clause,
    ResultRow row,
    Transaction txn,
    ExpressionEvaluator eval,
  ) {
    switch (clause) {
      case SetPropertyClause(:final alias, :final key, :final value):
        final binding = row.values[alias];
        final keyId = db.internPropKey(key);
        final propVal = _toPropValue(eval.eval(value, row));
        if (binding is Vid) {
          txn.setNodeProp(binding, keyId, propVal);
        } else if (binding is Eid) {
          txn.setEdgeProp(binding, keyId, propVal);
        } else {
          throw EvalException(
              'SET target $alias is not bound to a node or edge');
        }
      case DeleteClause(:final aliases):
        for (final a in aliases) {
          final binding = row.values[a];
          if (binding is Vid) {
            txn.delNode(binding);
          } else if (binding is Eid) {
            txn.delEdge(binding);
          } else {
            throw EvalException(
                'DELETE target $a is not bound to a node or edge');
          }
        }
    }
  }

  Future<QueryResult> _runCreate(
    CreatePlan plan,
    Map<String, Object?> params,
  ) async {
    final eval = ExpressionEvaluator(db.readView, params);
    final pattern = plan.pattern;
    final bindings = <String, Object?>{};
    await db.runTransaction((txn) {
      final startVid = _createNode(pattern.start, eval, txn);
      if (pattern.start.alias != null) {
        bindings[pattern.start.alias!] = startVid;
      }
      var prevVid = startVid;
      for (var i = 0; i < pattern.relationships.length; i++) {
        final rel = pattern.relationships[i];
        final dst = pattern.nodes[i];
        final dstVid = _createNode(dst, eval, txn);
        if (dst.alias != null) bindings[dst.alias!] = dstVid;
        final typeId = rel.types.isEmpty
            ? throw PlannerException(
                'CREATE relationship requires an explicit type — '
                'e.g. -[:KNOWS]->')
            : db.internEdgeType(rel.types.first);
        // Direction handling — v1 CREATE treats undirected as outgoing;
        // incoming swaps src/dst.
        final src = rel.direction == Direction.incoming ? dstVid : prevVid;
        final tgt = rel.direction == Direction.incoming ? prevVid : dstVid;
        final eid = txn.addEdge(
          src: src,
          dst: tgt,
          typeId: typeId,
          props: _evalInlineProps(rel.properties, eval),
        );
        if (rel.alias != null) bindings[rel.alias!] = eid;
        prevVid = dstVid;
      }
    }, durability: Durability.group);
    return _project(plan.returnClause, bindings, params);
  }

  /// MERGE single-node — match-or-create. Tries the match first (an
  /// embedded read run by the read [GqlExecutor]); if any row binds,
  /// projects the first match. Otherwise creates the node, then projects
  /// the new binding. v1 has no `ON MATCH` / `ON CREATE`.
  Future<QueryResult> _runMerge(
    MergePlan plan,
    Map<String, Object?> params,
  ) async {
    final node = plan.node;
    if (node.alias == null) {
      throw PlannerException('MERGE pattern must be aliased');
    }
    if (node.labels.isEmpty) {
      throw PlannerException('MERGE node requires at least one :Label (v1)');
    }
    // Pre-intern labels so the read planner can resolve them even when the
    // engine has never seen them before.
    for (final l in node.labels) {
      db.internLabel(l);
    }
    // Step 1 — try to MATCH (embedded read sub-plan).
    final matchStmt = MatchStatement(
      patterns: [
        PatternPart(start: node, relationships: const [], nodes: const []),
      ],
      where: null,
      returnClause: ReturnClause(
        distinct: false,
        items: [
          ReturnItem(expr: IdentifierExpr(node.alias!), alias: node.alias),
        ],
      ),
    );
    final readPlan = GqlPlanner(db.readView).plan(matchStmt);
    final hits = await GqlExecutor(db.readView).materialize(readPlan, params);
    if (hits.rows.isNotEmpty) {
      final boundVid = hits.rows.first.values[node.alias!] as Vid;
      return _project(plan.returnClause, {node.alias!: boundVid}, params);
    }
    // Step 2 — not found, CREATE.
    final eval = ExpressionEvaluator(db.readView, params);
    Vid? created;
    await db.runTransaction((txn) {
      final labelIds = <int>[for (final l in node.labels) db.internLabel(l)]
        ..sort();
      created = txn.addNode(
        labelIds: labelIds,
        props: _evalInlineProps(node.properties, eval),
      );
    }, durability: Durability.group);
    return _project(plan.returnClause, {node.alias!: created!}, params);
  }

  Vid _createNode(NodePattern n, ExpressionEvaluator eval, Transaction txn) {
    if (n.labels.isEmpty) {
      throw PlannerException('CREATE node requires at least one :Label');
    }
    final labelIds = <int>[for (final l in n.labels) db.internLabel(l)]..sort();
    return txn.addNode(
      labelIds: labelIds,
      props: _evalInlineProps(n.properties, eval),
    );
  }

  Map<int, PropValue> _evalInlineProps(
    Map<String, Expression> props,
    ExpressionEvaluator eval,
  ) {
    if (props.isEmpty) return const {};
    final out = <int, PropValue>{};
    for (final entry in props.entries) {
      final keyId = db.internPropKey(entry.key);
      out[keyId] = _toPropValue(eval.eval(entry.value, const ResultRow({})));
    }
    return out;
  }

  Future<QueryResult> _project(
    ReturnClause? returnClause,
    Map<String, Object?> bindings,
    Map<String, Object?> params,
  ) async {
    if (returnClause == null) return const QueryResult(columns: [], rows: []);
    final eval = ExpressionEvaluator(db.readView, params);
    final row = ResultRow(bindings);
    final columns = [
      for (var i = 0; i < returnClause.items.length; i++)
        returnClause.items[i].alias ?? 'col$i',
    ];
    final out = <String, Object?>{};
    for (var i = 0; i < returnClause.items.length; i++) {
      out[columns[i]] = eval.eval(returnClause.items[i].expr, row);
    }
    return QueryResult(columns: columns, rows: [ResultRow(out)]);
  }

  PropValue _toPropValue(Object? v) {
    if (v == null) return const PropNull();
    if (v is int) return PropInt(v);
    if (v is double) return PropDouble(v);
    if (v is bool) return PropBool(v);
    if (v is String) return PropString(v);
    throw PlannerException('cannot lift ${v.runtimeType} into a PropValue');
  }
}
