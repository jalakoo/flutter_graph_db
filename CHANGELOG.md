# Changelog

## Unreleased

### Multi-label nodes

Nodes can now carry an arbitrary set of labels (Neo4j-style
`(:Person:Employee)` semantics). Previously each node was restricted
to exactly one label. Spec'd in `flutter_graph_db_plans/5_MULTILABEL_PLAN.md`,
shipped as four PRs.

**New APIs**
- `GraphDb.hasLabel(vid, labelId)` and `GraphDb.labelsOf(vid)` — the
  read surface for the multi-label world. `hasLabel` is the
  alloc-free hot path (O(log k)); `labelsOf` returns a zero-copy
  Uint32List view at the boundary.
- `MutableGraphState.hasLabelEffective(vid, labelId)` and
  `effectiveLabelsOf(vid)` — overlay-aware analogues used by the
  applicator and executor.
- GQL: `(:A:B)` patterns evaluate as AND; `labels(n)` built-in
  returns the sorted-ascending list of label name strings; `'X' IN
  labels(n)` is the supported predicate for OR-style membership.
- `PlannerDiagnostic` channel — set `db.onPlannerDiagnostic` to
  receive non-fatal planner warnings. First user: `node.label`
  deprecation (see below).
- `Csr.fromEdges` accepts optional `labelRowPtr` + `labels` ragged
  inputs; falls back to single-label `labelOf` when omitted.
- Snapshot format bumped to v2 (ragged `labelRowPtr` + `labels`);
  v1 snapshots still decode under a fallback path (kept for two
  minor versions, then removed).

**Removed**
- `GraphDb.labelOf(vid) → int` deprecated shim. Replace with
  `db.hasLabel(vid, X)` or `db.labelsOf(vid).first` if you genuinely
  need the first label.
- `MutableGraphState.effectiveLabelOf(vid)` deprecated shim.
  Replace with `state.hasLabelEffective(vid, X)` or
  `state.effectiveLabelsOf(vid)`.

**Behaviour changes**
- GQL: `node.label` property access now resolves to a sorted
  `List<String>` of labels (previously a single label id). Existing
  code that does `node.label == 'Person'` will silently evaluate to
  false — switch to `'Person' IN labels(n)`. The planner emits a
  `PlannerDiagnostic.warning` when it detects this pattern.
- Sync: `ImportNode.label: String` → `ImportNode.labels: List<String>`.
  `RemoteNode.label: String?` → `RemoteNode.labels: List<String>`.
  Adapters generate `CREATE (n:A:B {})` for multi-label imports.
- Sync engine: remote nodes that arrive with empty labels are
  substituted with `'unlabeled_node'` (configurable via
  `SyncEngine.unlabeledFallback`) + a stderr warning fires on each
  substitution. Set the override to `null` to reject with
  `SyncException` instead.

**Constraints** behave Neo4j-style: a `UNIQUE (L, k)` or
`EXISTENCE (L, k)` constraint applies to any node that carries `L`,
regardless of other labels. `SetNodeLabels` re-validates all
affected constraints.

**Invariant**: every node must carry at least one label.
`SetNodeLabels` that would empty the set throws `ConstraintViolation`.
`(:A|B)` OR-pattern syntax is **not** supported yet — use a `WHERE`
clause with `IN labels(n)`.
