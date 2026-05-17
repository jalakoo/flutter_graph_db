/// OpenCypher subset parser / planner / executor for `graph_db_core`
/// (plan §8 / §14 Phase 3).
///
/// Imported solely for its extension on `GraphDb` — `db.executeQuery(...)`
/// becomes available wherever this library is in scope.
library;

// Exports land as sub-phases ship — see `4_PLAN.md` Phase 3 sub-table.
// 3A (lexer + parser + AST): done. 3B (planner + executor): done.
export 'src/ast.dart';
export 'src/engine_extension.dart' show GqlExecuteQuery;
export 'src/exec/executor.dart' show GqlExecutor;
export 'src/exec/expression_eval.dart' show EvalException;
export 'src/exec/result_row.dart' show QueryResult, ResultRow;
export 'src/lexer.dart' show Token, TokenKind, GqlLexer, GqlLexException;
export 'src/parser.dart' show GqlParser, GqlParseException;
export 'src/plan/logical_plan.dart';
export 'src/plan/planner.dart' show GqlPlanner, PlannerException;
export 'src/plan_cache.dart' show GqlPlanCache, kDefaultPlanCacheSize;
