/// `GraphDb.executeQuery` extension.
///
/// Adds the GQL entry point to the engine without coupling
/// `graph_db_core` to the parser / planner / executor. Apps that
/// don't import `graph_db_gql` see no `executeQuery` method — the
/// language code is tree-shaken out.
library;

import 'package:graph_db_core/graph_db_core.dart';

import 'ast.dart';
import 'diagnostics/planner_diagnostic.dart';
import 'exec/executor.dart';
import 'exec/result_row.dart';
import 'exec/write_executor.dart';
import 'parser.dart';
import 'plan/logical_plan.dart';
import 'plan/planner.dart';
import 'plan/write_plan.dart';
import 'plan_cache.dart';

/// Per-`GraphDb` plan cache — attached via [Expando] so the cache
/// lives alongside the engine without polluting `graph_db_core`'s
/// public surface.
final Expando<GqlPlanCache> _planCacheExpando =
    Expando<GqlPlanCache>('gqlPlanCache');

/// Per-`GraphDb` planner-diagnostic listener — opt-in. Apps that
/// don't set this see no diagnostics; set
/// `db.onPlannerDiagnostic = (d) { ... }` to receive them.
final Expando<PlannerDiagnosticListener> _diagListenerExpando =
    Expando<PlannerDiagnosticListener>('plannerDiagnostic');

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
    // Parse, plan (LRU-cached by query string — reads and writes alike),
    // execute. A write statement (CREATE / MERGE / MATCH…SET-or-DELETE)
    // plans to a WritePlan run in one transaction by GqlWriteExecutor; a
    // read plans to a LogicalPlan streamed by GqlExecutor.
    final stmt = GqlParser.fromSource(query).parse();
    final isWrite = stmt is CreateStatement ||
        stmt is MergeStatement ||
        (stmt is MatchStatement && stmt.mutations != null);
    final planner = GqlPlanner(readView, onDiagnostic: onPlannerDiagnostic);
    final plan = gqlPlanCache.getOrBuild(
      query,
      () => isWrite ? planner.planWrite(stmt) : planner.plan(stmt),
    );
    if (plan is WritePlan) {
      return GqlWriteExecutor(this).execute(plan, params);
    }
    return GqlExecutor(readView).materialize(plan as LogicalPlan, params);
  }

  /// The plan cache for this engine. Lazily created on first access.
  /// Exposed so callers can `.invalidateAll()` after schema changes
  /// (the engine doesn't currently auto-invalidate on intern).
  GqlPlanCache get gqlPlanCache =>
      _planCacheExpando[this] ??= GqlPlanCache();

  /// Non-fatal planner observability — fires during plan-build for
  /// deprecated syntax and other warnings. Silent by default; set a
  /// listener to receive `PlannerDiagnostic`s. Mirrors the
  /// `onIndexSizeEvent` pattern in `graph_db_core`. Currently
  /// surfaces only the multi-label-rollout `node.label` deprecation
  /// (`5_MULTILABEL_PLAN.md` §19.9).
  PlannerDiagnosticListener? get onPlannerDiagnostic =>
      _diagListenerExpando[this];
  set onPlannerDiagnostic(PlannerDiagnosticListener? listener) {
    _diagListenerExpando[this] = listener;
  }
}
