/// Cypher AST (plan §8 / §14 Phase 3A).
///
/// v1 read subset: `MATCH (...) [WHERE ...] RETURN ...`. The grammar
/// is intentionally compact — writes (`CREATE` / `DELETE` / `SET` /
/// `MERGE`), variable-length paths (`*1..n`), and aggregations land in
/// later sub-phases.
///
/// All AST nodes are immutable. The parser builds them; the planner
/// reads them.
library;

// ---------------------------------------------------------------------------
// Statements

/// Top-level statement. v1 ships [MatchStatement]; future sub-phases
/// add `CreateStatement` / `DeleteStatement` / `SetStatement` /
/// `MergeStatement`. Sealed so future planner / executor switches stay
/// exhaustive.
sealed class GqlStatement {
  const GqlStatement();
}

class MatchStatement extends GqlStatement {
  final List<PatternPart> patterns;
  final Expression? where;

  /// Optional mutating clauses (plan §8 / §14 Phase 3E). `SET` /
  /// `DELETE` run per matched row inside an engine-side transaction.
  final List<MutatingClause>? mutations;

  /// `null` when the statement is write-only (no RETURN).
  final ReturnClause? returnClause;

  /// Optional ORDER BY clause (plan §8 / §14 Phase 3C). `null` when
  /// the query has no ordering. Items applied in declared order.
  final List<OrderByItem>? orderBy;

  /// SKIP n — drops the first `n` result rows. `null` when absent.
  final int? skip;

  /// LIMIT n — caps the result row count. `null` when absent.
  final int? limit;

  const MatchStatement({
    required this.patterns,
    required this.where,
    required this.returnClause,
    this.mutations,
    this.orderBy,
    this.skip,
    this.limit,
  });
}

/// Top-level standalone `CREATE (n:Label {props})` statement
/// (plan §8 / §14 Phase 3E). Multi-pattern + edge creation through
/// CREATE is supported by the single-pattern parser; relationships
/// connect newly-bound nodes.
class CreateStatement extends GqlStatement {
  final PatternPart pattern;
  final ReturnClause? returnClause;
  const CreateStatement({required this.pattern, this.returnClause});
}

/// `MERGE (n:Label {props})` — match-or-create (plan §8 / §14 Phase 3E
/// polish). v1 supports single-node patterns only; relationship-form
/// MERGE deferred. No `ON MATCH` / `ON CREATE` clauses in v1.
class MergeStatement extends GqlStatement {
  final NodePattern pattern;
  final ReturnClause? returnClause;
  const MergeStatement({required this.pattern, this.returnClause});
}

/// One mutating clause attached to a MATCH (plan §8 / §14 Phase 3E).
sealed class MutatingClause {
  const MutatingClause();
}

/// `SET <ident>.<key> = <expr>`. Multiple assignments inside one SET
/// keyword become multiple [SetPropertyClause] entries.
class SetPropertyClause extends MutatingClause {
  final String alias;
  final String key;
  final Expression value;
  const SetPropertyClause({
    required this.alias,
    required this.key,
    required this.value,
  });
}

/// `DELETE <ident>[, <ident>]*` — cascade-delete each bound node/edge.
class DeleteClause extends MutatingClause {
  final List<String> aliases;
  const DeleteClause(this.aliases);
}

// ---------------------------------------------------------------------------
// Patterns

/// One MATCH pattern: `(a:Label)-[:TYPE]->(b:Label)`.
///
/// Linear-chain only — disjoint commas-separated patterns are
/// represented as multiple [PatternPart]s in [MatchStatement.patterns].
/// Branching patterns (`(a)-(b), (a)-(c)`) decompose into multiple
/// PatternParts that share variable bindings.
class PatternPart {
  /// Starting node.
  final NodePattern start;

  /// Subsequent (relationship, node) pairs. Same length on both sides.
  /// `relationships[i]` connects `nodes[i-1]` (or [start] for `i==0`)
  /// to `nodes[i]`.
  final List<RelationshipPattern> relationships;
  final List<NodePattern> nodes;

  const PatternPart({
    required this.start,
    required this.relationships,
    required this.nodes,
  });
}

class NodePattern {
  /// `null` for anonymous patterns like `()` or `(:Person)`.
  final String? alias;

  /// Empty when no `:Label` filter. Multi-label (`:A:B`) is captured
  /// but the v1 storage is single-label — the planner ignores all but
  /// the first.
  final List<String> labels;

  /// Inline property filter `{key: value}`. Lowered to a `WHERE`
  /// conjunction by the planner.
  final Map<String, Expression> properties;

  const NodePattern({
    required this.alias,
    required this.labels,
    required this.properties,
  });
}

enum Direction { outgoing, incoming, undirected }

class RelationshipPattern {
  /// `null` for anonymous patterns like `-->`.
  final String? alias;

  /// Empty when no `:TYPE` filter. Multi-type (`:A|B`) deferred to a
  /// later sub-phase; the parser accepts a single type in 3A.
  final List<String> types;
  final Direction direction;
  final Map<String, Expression> properties;

  /// Variable-length quantifier (plan §8 / §14 Phase 3D). `null`
  /// means single-hop. When set, [minHops] / [maxHops] define the
  /// inclusive bounds (e.g. `*1..3` → min=1, max=3; `*..3` → min=1;
  /// `*2..` → max = unlimited; `*` → both unbounded → min=1, max=null).
  /// The executor walks via BFS with the bounds applied.
  final int? minHops;
  final int? maxHops;
  bool get isVarLength => minHops != null || maxHops != null;

  const RelationshipPattern({
    required this.alias,
    required this.types,
    required this.direction,
    required this.properties,
    this.minHops,
    this.maxHops,
  });
}

// ---------------------------------------------------------------------------
// Expressions

sealed class Expression {
  const Expression();
}

/// Literal int / double / string / bool / null.
class LiteralExpr extends Expression {
  final Object? value;
  const LiteralExpr(this.value);
}

/// Reference to a bound name (pattern alias).
class IdentifierExpr extends Expression {
  final String name;
  const IdentifierExpr(this.name);
}

/// Property access: `n.name`. [target] is typically an [IdentifierExpr].
class PropertyAccessExpr extends Expression {
  final Expression target;
  final String key;
  const PropertyAccessExpr(this.target, this.key);
}

/// `$paramName` — bound at execute time.
class ParameterExpr extends Expression {
  final String name;
  const ParameterExpr(this.name);
}

enum BinaryOp {
  and,
  or,
  eq,
  neq,
  lt,
  lte,
  gt,
  gte,
  plus,
  minus,
  mul,
  div,
  mod,
}

class BinaryOpExpr extends Expression {
  final BinaryOp op;
  final Expression left;
  final Expression right;
  const BinaryOpExpr(this.op, this.left, this.right);
}

enum UnaryOp { not, neg }

class UnaryOpExpr extends Expression {
  final UnaryOp op;
  final Expression operand;
  const UnaryOpExpr(this.op, this.operand);
}

// ---------------------------------------------------------------------------
// RETURN

class ReturnClause {
  final bool distinct;
  final List<ReturnItem> items;
  const ReturnClause({required this.distinct, required this.items});
}

class ReturnItem {
  final Expression expr;
  final String? alias;
  const ReturnItem({required this.expr, required this.alias});
}

/// Aggregate function call (plan §8 / §14 Phase 3C).
///
/// Six standard aggregates: COUNT, SUM, AVG, MIN, MAX, COLLECT.
/// `COUNT(*)` is special-cased — its [argument] is null. All others
/// require an inner expression.
enum AggregateFn { count, sum, avg, min, max, collect }

class AggregateExpr extends Expression {
  final AggregateFn fn;
  /// `null` for `COUNT(*)`; non-null for every other call.
  final Expression? argument;
  const AggregateExpr({required this.fn, required this.argument});
}

/// One ORDER BY item: `expr [ASC|DESC]`.
class OrderByItem {
  final Expression expr;
  final bool ascending;
  const OrderByItem({required this.expr, required this.ascending});
}

/// Built-in scalar function call (plan §8 Cypher-compat / §14 Phase 3F).
///
/// v1 ships `size()`, `length()`, `coalesce()`. Aggregations are
/// represented by the separate [AggregateExpr] — different planning +
/// execution path.
enum BuiltinFn { size, length, coalesce }

class FunctionCallExpr extends Expression {
  final BuiltinFn fn;
  final List<Expression> arguments;
  const FunctionCallExpr({required this.fn, required this.arguments});
}
