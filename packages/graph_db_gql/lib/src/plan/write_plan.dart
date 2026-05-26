/// Write-plan IR — the mutating counterpart to [LogicalPlan] (plan A4).
///
/// Produced by `GqlPlanner.planWrite`, executed by `GqlWriteExecutor` in
/// one transaction. The read and write paths share **one planner and one
/// pattern-binding model**; execution is *specialized* — reads stream
/// (`GqlExecutor.execute → Stream<ResultRow>`), writes run in a txn. Reads
/// embedded in a write (MERGE's match, MATCH…SET's pattern) are ordinary
/// [LogicalPlan]s the read executor runs.
library;

import '../ast.dart';
import 'logical_plan.dart';

/// Root of the write-plan hierarchy. `sealed` so every write statement the
/// engine grows must be handled exhaustively by the write executor.
sealed class WritePlan {
  const WritePlan();
}

/// `CREATE (a:L {..})-[:T]->(b:L) [RETURN ..]` — constructs the linear
/// node/relationship chain in order, then projects [returnClause] over the
/// freshly-bound aliases. Label/type names are interned and inline-prop
/// expressions evaluated at execution time, inside the write transaction.
class CreatePlan extends WritePlan {
  final PatternPart pattern;
  final ReturnClause? returnClause;
  const CreatePlan({required this.pattern, this.returnClause});
}

/// `MERGE (n:L {props}) [RETURN ..]` — match-or-create on a single node
/// (v1: no relationship-form MERGE, no `ON MATCH`/`ON CREATE`). The
/// executor runs the match as an embedded read (reusing the read
/// `GqlExecutor`); on a hit it projects the bound alias, otherwise it
/// creates the node and projects that.
class MergePlan extends WritePlan {
  final NodePattern node;
  final ReturnClause? returnClause;
  const MergePlan({required this.node, this.returnClause});
}

/// `MATCH … SET/DELETE … [RETURN …]` — runs [bindingPlan] (the MATCH with
/// a passthrough RETURN of all aliases) to bind rows, applies [mutations]
/// in one transaction, then — if [projectionPlan] is non-null — re-runs
/// the match with the user's RETURN to project the **post-mutation**
/// state. Both plans are built **once** by the planner, so a repeated
/// query pays no per-execution re-planning (the prior imperative path
/// planned the match twice on every call).
class MutatePlan extends WritePlan {
  /// MATCH + passthrough RETURN of every alias → the Vid/Eid binding rows
  /// the mutation step consumes.
  final LogicalPlan bindingPlan;
  final List<MutatingClause> mutations;

  /// MATCH + the user's RETURN (+ ORDER BY / SKIP / LIMIT), or `null` when
  /// the statement carries no RETURN.
  final LogicalPlan? projectionPlan;

  const MutatePlan({
    required this.bindingPlan,
    required this.mutations,
    required this.projectionPlan,
  });
}
