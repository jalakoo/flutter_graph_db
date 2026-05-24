# Backlog

Engine improvements requested by a downstream consumer, triaged and
verified against the code on 2026-05-24, then implemented the same day.

**Status: shipped.** All seven items landed (with one sub-item of #5
deferred — see below). New tests: graph_db_core 224 → green,
graph_db_wal 76 → green, graph_db_gql 95 → green. No commits yet (per
the defer-commits convention).

---

## P0

### ✅ Auto-checkpoint the WAL
- **Shipped:** `CheckpointPolicy` + `CheckpointCoordinator` in
  `graph_db_wal`, plus an `afterCommit` post-commit hook on `GraphDb`.
  Crosses a WAL-byte (default 8 MiB) and/or commit-count threshold →
  synchronously merges + encodes + captures the WAL tip, then
  asynchronously writes the snapshot and truncates the WAL.
- **Crash-safe:** snapshot is made durable *before* the WAL truncate;
  the WAL offset is captured synchronously so interleaved commits can't
  shift the truncate point. A crash leaving the snapshot ahead of an
  un-truncated WAL still recovers correctly (replay is idempotent —
  proven by the existing `crash mid-truncate` test).
- **Files:** `graph_db_wal/lib/src/checkpoint.dart`;
  `graph_db_core/lib/src/graph_db.dart` (`afterCommit`).
- **Tests:** `graph_db_wal/test/checkpoint_test.dart`.

### ✅ One-call durable open — `openGraphDbAtPath`
- **Shipped:** `openGraphDbAtPath(path, {codec, checkpointPolicy})`
  (native only, behind `package:graph_db_wal/io_wal_store.dart`) wires an
  `IoWalStore` at `<path>` + `IoSnapshotStore` at `<path>.snapshot`,
  restores the latest snapshot, replays the WAL tail, and attaches a
  `CheckpointCoordinator`. Returns a `DurableGraphDb` handle
  (`.db`, `.checkpointNow()`, `.close()`). The two-step
  `openWalBackedGraphDb` flow stays available.
- **Files:** `graph_db_wal/lib/src/durable_graph_db.dart`.
- **Tests:** `graph_db_wal/test/open_graph_db_at_path_test.dart`.

---

## P1

### ✅ SnapshotStore port  ⟵ keystone
- **Shipped:** abstract `SnapshotStore` (single-latest: `write` /
  `read` / `delete` / `close`) + `InMemorySnapshotStore` +
  `IoSnapshotStore` (atomic temp-write + rename; Windows delete-then-
  rename fallback). Mirrors the `WalStore` port + adapter set.
- **Files:** `graph_db_wal/lib/src/snapshot_store.dart`,
  `in_memory_snapshot_store.dart`, `io_snapshot_store.dart`.
- **Tests:** `graph_db_wal/test/snapshot_store_test.dart` (incl.
  encode → store → load → decode round-trip).

### ⚠️ findNodeByProp — shipped; built-in logical-id index — deferred
- **Shipped:** `db.findNodeByProp(labelId, keyId, value) → Vid?` and
  `db.findNodesByProp(...) → List<Vid>`, read-your-writes scans over the
  labelled set (uses `PropValue` value-equality, all column types).
  Plus non-interning name→id resolvers `db.labelId/edgeTypeId/propKeyId`
  so reads-by-name don't pollute the catalog.
- **Files:** `graph_db_core/lib/src/graph_db.dart`.
- **Tests:** `graph_db_core/test/find_node_by_prop_test.dart`.
- **Deferred — built-in logical-id index.** Blocked on a prerequisite:
  `logicalId` is currently **neither durable nor readable** — it lives
  only in the overlay's `AddedNode`, isn't persisted by `encodeSnapshot`,
  and has no per-vid read accessor. A reliable logical-id index first
  needs durable, readable logicalId storage (a cross-cutting change to
  the snapshot codec + merge protocol + state). **Workaround today:**
  store your own stable id as a property and use `findNodeByProp` (with
  a unique `createNodePropertyIndex` for large sets). Tracked as a
  follow-up: "durable + readable logicalId, then a logicalId→Vid index".

### ✅ Idempotent `close()`
- **Shipped:** a `_closed` guard makes the 2nd+ `GraphDb.close()` a
  no-op (was: the doc warned "Safe to call once").
- **Files:** `graph_db_core/lib/src/graph_db.dart`.
- **Tests:** `graph_db_core/test/close_test.dart`.

---

## P2

### ✅ String-keyed convenience overloads
- **Shipped:** `txn.addNodeNamed(labels: [...], props: {'k': ...})`,
  `txn.addEdgeNamed(type: '...', ...)`, `txn.setNodePropNamed` /
  `setEdgePropNamed` — auto-intern names through the engine's journaled
  path (interns are recorded in the WAL and survive recovery). Int-keyed
  methods remain the documented hot path.
- **Files:** `graph_db_core/lib/src/transaction.dart`,
  `graph_db.dart` (wires the interners into the txn).
- **Tests:** `graph_db_core/test/string_keyed_test.dart`,
  `graph_db_wal/test/string_keyed_recovery_test.dart`.

### ✅ Vid-typed `labelScan`
- **Shipped:** `db.labelScanVids(labelId) → Iterable<Vid>`, a lazy view
  over the same index (no array copy; `Vid` is a zero-cost wrap). Raw
  `labelScan` → `Uint32List` stays for the allocation-free hot path.
- **Files:** `graph_db_core/lib/src/graph_db.dart`.
- **Tests:** `graph_db_core/test/label_scan_vids_test.dart`.

---

## Done earlier this session (2026-05-24) — documentation papercuts

- **Read-your-writes clarity** — corrected the stale `mergeNow()`
  guidance in the umbrella README.
- **`Vid` wrapping on `labelScan`** — documented (and now superseded by
  `labelScanVids` above).
- **WAL-growth gotcha** — documented; auto-checkpoint + `openGraphDbAtPath`
  now remove it for apps that opt in.
