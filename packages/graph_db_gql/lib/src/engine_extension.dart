/// `GraphDb.executeQuery` extension (plan §8 / §14 Phase 3B).
///
/// Adds the GQL entry point to the engine without coupling
/// `graph_db_core` to the parser / planner / executor. Apps that
/// don't import `graph_db_gql` see no `executeQuery` method — the
/// language code is tree-shaken out.
library;

import 'package:graph_db_core/graph_db_core.dart';

import 'ast.dart';
import 'exec/executor.dart';
import 'exec/expression_eval.dart';
import 'exec/result_row.dart';
import 'parser.dart';
import 'plan/planner.dart';
import 'plan_cache.dart';

/// Per-`GraphDb` plan cache — attached via [Expando] so the cache
/// lives alongside the engine without polluting `graph_db_core`'s
/// public surface.
final Expando<GqlPlanCache> _planCacheExpando =
    Expando<GqlPlanCache>('gqlPlanCache');

extension GqlExecuteQuery on GraphDb {
  /// Parses, plans (LRU-cached), and executes [query] against this
  /// database. Returns a materialised [QueryResult] — every row
  /// collected into memory.
  ///
  /// `params` binds `$paramName` expressions inside the query.
  /// Defaults to empty.
  ///
  /// Throws [GqlLexException] / [GqlParseException] on bad syntax;
  /// [PlannerException] on unknown labels / edge types / shape
  /// constraints the v1 planner doesn't yet support;
  /// `EvalException` on type errors at runtime.
  Future<QueryResult> executeQuery(
    String query, [
    Map<String, Object?> params = const {},
  ]) async {
    // Parse once. We can't always cache the plan because write
    // statements run in a transaction (no cacheable LogicalPlan
    // — they go through a different path). Read-only plans land in
    // the LRU cache by query string.
    final stmt = GqlParser.fromSource(query).parse();
    if (stmt is CreateStatement) {
      return _executeCreate(stmt, params);
    }
    if (stmt is MergeStatement) {
      return _executeMerge(stmt, params);
    }
    if (stmt is MatchStatement && stmt.mutations != null) {
      return _executeMatchWithMutations(stmt, params);
    }
    final cache = gqlPlanCache;
    final plan = cache.getOrBuild(query, () => GqlPlanner(this).plan(stmt));
    return GqlExecutor(this).materialize(plan, params);
  }

  /// CREATE — runs inside a write transaction. Supports the same
  /// pattern shape as MATCH (linear chain of nodes + relationships
  /// with optional aliases / labels / inline props).
  Future<QueryResult> _executeCreate(
    CreateStatement stmt,
    Map<String, Object?> params,
  ) async {
    final eval = ExpressionEvaluator(this, params);
    final bindings = <String, Object?>{};
    await runTransaction((txn) {
      // Start node
      final startVid = _createNodePattern(stmt.pattern.start, eval, txn);
      if (stmt.pattern.start.alias != null) {
        bindings[stmt.pattern.start.alias!] = startVid;
      }
      var prevVid = startVid;
      for (var i = 0; i < stmt.pattern.relationships.length; i++) {
        final rel = stmt.pattern.relationships[i];
        final dst = stmt.pattern.nodes[i];
        final dstVid = _createNodePattern(dst, eval, txn);
        if (dst.alias != null) bindings[dst.alias!] = dstVid;
        final typeId = rel.types.isEmpty
            ? throw PlannerException(
                'CREATE relationship requires an explicit type — '
                'e.g. -[:KNOWS]->')
            : state.strings.internEdgeType(rel.types.first);
        // Direction handling — for v1 CREATE we treat undirected as
        // outgoing; incoming swaps src/dst.
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
    return _projectBindings(stmt.returnClause, bindings, params);
  }

  Vid _createNodePattern(
    NodePattern n,
    ExpressionEvaluator eval,
    Transaction txn,
  ) {
    if (n.labels.isEmpty) {
      throw PlannerException(
        'CREATE node requires at least one :Label',
      );
    }
    final labelId = state.strings.internLabel(n.labels.first);
    return txn.addNode(
      labelIds: [labelId],
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
      final keyId = state.strings.internPropKey(entry.key);
      final value = eval.eval(entry.value, const ResultRow({}));
      out[keyId] = _toPropValue(value);
    }
    return out;
  }

  PropValue _toPropValue(Object? v) {
    if (v == null) return const PropNull();
    if (v is int) return PropInt(v);
    if (v is double) return PropDouble(v);
    if (v is bool) return PropBool(v);
    if (v is String) return PropString(v);
    throw PlannerException(
      'cannot lift ${v.runtimeType} into a PropValue',
    );
  }

  /// MATCH ... SET/DELETE — materialise the read rows, then apply
  /// mutations inside one transaction. Optional RETURN projects the
  /// **post-mutation** values.
  Future<QueryResult> _executeMatchWithMutations(
    MatchStatement stmt,
    Map<String, Object?> params,
  ) async {
    // Plan the read part WITHOUT the mutations (they're applied
    // imperatively below). Always synthesise a passthrough RETURN of
    // all aliased bindings so the mutation step sees Vid/Eid handles
    // rather than projected property values.
    final readStmt = MatchStatement(
      patterns: stmt.patterns,
      where: stmt.where,
      returnClause: ReturnClause(
        distinct: false,
        items: _bindingsAsReturnItems(stmt.patterns),
      ),
    );
    final plan = GqlPlanner(this).plan(readStmt);
    final preRows = <ResultRow>[];
    await for (final row in GqlExecutor(this).execute(plan, params)) {
      preRows.add(row);
    }
    final eval = ExpressionEvaluator(this, params);
    await runTransaction((txn) {
      for (final row in preRows) {
        for (final clause in stmt.mutations!) {
          _applyMutation(clause, row, txn, eval);
        }
      }
    }, durability: Durability.group);
    if (stmt.returnClause == null) {
      return const QueryResult(columns: [], rows: []);
    }
    // Re-plan + re-execute with the user's RETURN to project the
    // post-mutation state. The mutations already landed, so the next
    // match sees the new values.
    final projStmt = MatchStatement(
      patterns: stmt.patterns,
      where: stmt.where,
      returnClause: stmt.returnClause,
      orderBy: stmt.orderBy,
      skip: stmt.skip,
      limit: stmt.limit,
    );
    final projPlan = GqlPlanner(this).plan(projStmt);
    return GqlExecutor(this).materialize(projPlan, params);
  }

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
          out.add(ReturnItem(
            expr: IdentifierExpr(n.alias!),
            alias: n.alias,
          ));
        }
      }
      for (final r in p.relationships) {
        if (r.alias != null) {
          out.add(ReturnItem(
            expr: IdentifierExpr(r.alias!),
            alias: r.alias,
          ));
        }
      }
    }
    return out;
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
        final keyId = state.strings.internPropKey(key);
        final v = eval.eval(value, row);
        final propVal = _toPropValue(v);
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

  /// MERGE single-node — match-or-create. Tries a MATCH first; if any
  /// row binds, returns the projection over the first match. Otherwise
  /// opens a write txn + creates the node, then projects the new
  /// binding. v1 has no `ON MATCH` / `ON CREATE` clauses (plan §8).
  Future<QueryResult> _executeMerge(
    MergeStatement stmt,
    Map<String, Object?> params,
  ) async {
    final node = stmt.pattern;
    if (node.alias == null) {
      throw PlannerException('MERGE pattern must be aliased');
    }
    if (node.labels.isEmpty) {
      throw PlannerException(
        'MERGE node requires at least one :Label (v1)',
      );
    }
    // Pre-intern the label so the read planner can resolve it even
    // when the engine has never seen this label before.
    state.strings.internLabel(node.labels.first);
    // Step 1 — try to MATCH.
    final matchStmt = MatchStatement(
      patterns: [
        PatternPart(start: node, relationships: const [], nodes: const []),
      ],
      where: null,
      returnClause: ReturnClause(
        distinct: false,
        items: [
          ReturnItem(
            expr: IdentifierExpr(node.alias!),
            alias: node.alias,
          ),
        ],
      ),
    );
    final readPlan = GqlPlanner(this).plan(matchStmt);
    final hits = await GqlExecutor(this).materialize(readPlan, params);
    if (hits.rows.isNotEmpty) {
      final boundVid = hits.rows.first.values[node.alias!] as Vid;
      return _projectBindings(
        stmt.returnClause,
        {node.alias!: boundVid},
        params,
      );
    }
    // Step 2 — not found, CREATE.
    final eval = ExpressionEvaluator(this, params);
    Vid? created;
    await runTransaction((txn) {
      final labelId = state.strings.internLabel(node.labels.first);
      created = txn.addNode(
        labelIds: [labelId],
        props: _evalInlineProps(node.properties, eval),
      );
    }, durability: Durability.group);
    return _projectBindings(
      stmt.returnClause,
      {node.alias!: created!},
      params,
    );
  }

  Future<QueryResult> _projectBindings(
    ReturnClause? returnClause,
    Map<String, Object?> bindings,
    Map<String, Object?> params,
  ) async {
    if (returnClause == null) {
      return const QueryResult(columns: [], rows: []);
    }
    final eval = ExpressionEvaluator(this, params);
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

  /// The plan cache for this engine. Lazily created on first access.
  /// Exposed so callers can `.invalidateAll()` after schema changes
  /// (the engine doesn't currently auto-invalidate on intern).
  GqlPlanCache get gqlPlanCache =>
      _planCacheExpando[this] ??= GqlPlanCache();
}
