/// OpenCypher subset parser / planner / executor for `graph_db_core`
///.
///
/// Imported solely for its extension on `GraphDb` — `db.executeQuery(...)`
/// becomes available wherever this library is in scope.
library;

// Public surface: lexer + parser + AST + planner + executor.
export 'src/ast.dart';
export 'src/diagnostics/planner_diagnostic.dart'
    show
        PlannerDiagnostic,
        PlannerDiagnosticListener,
        PlannerDiagnosticSeverity;
export 'src/engine_extension.dart' show GqlExecuteQuery;
export 'src/exec/executor.dart' show GqlExecutor;
export 'src/exec/expression_eval.dart' show EvalException;
export 'src/exec/result_row.dart' show QueryResult, ResultRow;
export 'src/lexer.dart' show Token, TokenKind, GqlLexer, GqlLexException;
export 'src/parser.dart' show GqlParser, GqlParseException;
export 'src/plan/logical_plan.dart';
export 'src/plan/planner.dart' show GqlPlanner, PlannerException;
export 'src/plan_cache.dart' show GqlPlanCache, kDefaultPlanCacheSize;
