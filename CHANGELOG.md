# Changelog

## Unreleased

### Correctness fixes

Found by a review of the engine against its own documented contracts.

**Deleted nodes no longer come back after a merge.** `Csr` had no
tombstone field: `foldOverlayIntoCsr` built a tombstone bitmap,
`Csr.fromEdges` used it only to filter `labelIndex` and then dropped it,
and `installMergedCsr` cleared the overlay that held the delete. After a
merge the vid was visible again — `isNodeVisible` returned `true`,
`scanNodes` (so GQL `MATCH (n)`) yielded a phantom label-less row, and
edges and properties could be written to the dead node. It survived a
snapshot round-trip too, so the delete was durably lost.

- `Csr.nodeTombstones` (nullable `Uint8List`) + `Csr.isTombstoned` /
  `Csr.tombstoneCount`. `null` when nothing has been deleted, so a
  delete-free graph pays no memory.
- The fold unions base tombstones with the overlay's, and the node count
  now covers deleted vids — a node added *and* deleted before the first
  merge previously had no row for its tombstone to live in, which let its
  vid be allocated twice.
- Tombstones ride the worker-isolate hand-off (`TransferableCsr`) and
  persist in the snapshot (**format v3**).
- `MutableGraphState.isNodeTombstoned` is the new "deleted, in any
  generation" predicate.

**Edge-property indexes are now maintained.** `IndexRegistry` had
`beforeNodeWrite` / `afterNodeWrite` / `onNodeDeleted` and no edge
counterparts, so `createEdgePropertyIndex` registered an index that
nothing ever updated: after `setEdgeProp` a lookup for the new value
found nothing and a lookup for the old value returned a dead hit.

- `beforeEdgeWrite` / `afterEdgeWrite` / `onEdgeDeleted`, wired into
  `applyAddEdge`, `applySetEdgeProp`, `applyDelEdgeProp` and
  `applyDelEdge`.
- A deleted edge's property values are dropped, mirroring `applyDelNode`.
- `EqualityRange(unique: true, incremental: true)` is now rejected
  instead of silently downgraded — enforcement reads the sorted arrays,
  which is only sound because a unique index is always rebuilt.

**`IoWalStore.truncate` is crash-safe.** It reopened the WAL with
`FileMode.write` (truncating to zero) before writing the retained tail
back; a crash inside that window lost every commit acked after the
snapshot was captured — exactly the data the snapshot does not cover.
It now streams the tail into a temp file, fsyncs, and renames over the
WAL. Peak memory is one 64 KiB buffer rather than the whole tail.
Handle operations (`append` / `sync` / `truncate` / `close`) are
serialized, closing a race where group-commit's `sync()` landed while the
handle was closed for the rename.

**Unique constraints are label-scoped.** `UNIQUE (Label, key)` was backed
by a global unique index, so a node carrying an unrelated label was
rejected for duplicating a value under someone else's constraint. New
`IndexSpec.labelScope` scopes enforcement; the index still covers the
whole column, and enforcement scans the equal range so an out-of-scope
row can't mask an in-scope duplicate. `SetNodeLabels` re-checks
uniqueness when a node gains a scoped label.

### New

- **Journaled schema.** `declareNodeColumn` / `declareEdgeColumn` and
  index create/drop are recorded in the WAL (`DeclareColumn`,
  `DeclareIndex`, `DropIndex`) and carried in the snapshot, so column
  type-locks and index declarations survive a restart instead of having to
  be re-declared on every open. Index contents stay derived and are
  rebuilt from the recovered columns.
- **Durable sync progress.** `SyncStateStore` port with
  `InMemorySyncStateStore` and `IoSyncStateStore` (atomic temp-write +
  rename), plus `SyncEngine.stateStore` and `SyncEngine.restore()`.
  Per-target high-water marks are persisted per acknowledged batch, so a
  restart no longer re-ships the entire retained WAL.
- `GraphDb.isClosed`. `runTransaction` and `bulkAddEdges` now throw after
  `close()` — previously an in-memory engine silently accepted writes it
  could never persist.
- `PropertyStore.columnKeyIds`, replacing a bounded keyId scan in the
  snapshot encoder that silently dropped columns whose keyId sat past
  `columnCount + 256`.

### Changed

- **Merge install is now a pointer swap.** `installMergedCsr` no longer
  rebuilds the `eid → endpoint` maps; `Csr.fromEdges` produces them, so
  the worker computes them and the main isolate just re-binds. This
  removed three O(V+E) passes that ran on the main isolate after every
  fold — the cost the "~30 µs hand-off" claim assumed away.
- `findNodeByProp` / `findNodesByProp` compare against the raw typed
  column instead of boxing a `PropValue` per candidate row, and skip the
  scan outright when the query type can't match the column.
- `bulkAddEdges` fires `afterCommit`, so a bulk import is visible to the
  auto-checkpoint coordinator. It also clears `activeTxnHasWrites`.
- Node deletion batches index rebuilds across the edge cascade
  (`IndexRegistry.beginBatch` / `endBatch`) instead of rebuilding every
  non-incremental index once per incident edge.
- WAL recovery streams both passes; only the committed-txn-id set is held
  in memory, not every decoded op.
- `applyDelNodeProp` throws on an absent vid, matching
  `applySetNodeProp`.
- `IndexPriority.high` is documented as not yet implemented (it behaves
  as `low`). Declarations persist regardless of the flag.

### Fixed docs

- The example app is `graph_db_core`-only with JSON-snapshot persistence
  — it was described as WAL-backed with six tabs (it has four), and it
  exercises neither the umbrella, the WAL, nor GQL.
- The git-dependency `path:` in both READMEs had an extra
  `flutter_graph_db/` segment, so the documented install failed.
- Test count (~370 → ~580); the "rotated 16 MB segments" claim now says
  which adapter actually does that (only the in-memory one).
- Five package descriptions still said "Stub — implementation lands in
  Phase N" for code that shipped. The Bolt and RESP adapters are
  explicitly marked unvalidated against a live server.

### Read-your-writes reads

The public read API is now read-your-writes: a committed mutation is
visible to the engine's own reads immediately, with no
`db.mergeNow()`. Merge becomes a pure background-compaction
detail, never a correctness step. Spec'd in
`6_IMPROVED_API_PLAN.md` (external plan doc, not in this repo).

**Changed**
- `GraphDb.labelScan`, `forEachOutNeighbor` / `forEachInNeighbor`,
  `nodeCount` / `edgeCount`, and `outDegree` / `inDegree` are now
  overlay-aware. (Property reads and the GQL `MATCH` surface already
  were.)
- Fixes a latent `RangeError` when traversing or measuring the degree
  of an overlay-added node before the first merge.

**New APIs**
- `GraphDb.hasPendingWrites` — `true` while committed writes sit in the
  overlay (CSR not yet refreshed).
- `MutableGraphState.effectiveLabelScan` / `effectiveNodeCount` /
  `effectiveEdgeCount`; `effectiveOutDegree` / `effectiveInDegree` gain
  an O(1) clean-overlay fast path.

**Unchanged by design**
- The allocation-free primitive range API (`outRangeStart` /
  `outRangeEnd` / `outNeighborAt` / …) keeps snapshot-of-last-merge
  semantics — the documented exception to read-your-writes. Pair it
  with `hasPendingWrites`, or call `mergeNow()` first.

### Multi-label nodes

Nodes can now carry an arbitrary set of labels (Neo4j-style
`(:Person:Employee)` semantics). Previously each node was restricted
to exactly one label. Spec'd in `5_MULTILABEL_PLAN.md` (external plan doc, not in this repo),
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
