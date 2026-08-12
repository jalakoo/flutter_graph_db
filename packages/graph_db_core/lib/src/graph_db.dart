import 'dart:async';
import 'dart:typed_data';

import 'applicator.dart';
import 'bulk_edge.dart';
import 'constraints/constraint_catalog.dart';
import 'csr.dart';
import 'durability.dart';
import 'exceptions.dart';
import 'graph_schema.dart';
import 'identity/uuid_v7.dart';
import 'ids.dart';
import 'isolation.dart';
import 'merge/merge_fold.dart';
import 'mutable_graph_state.dart';
import 'overlay/delta_overlay.dart';
import 'prop_value.dart';
import 'read_view.dart';
import 'property_store.dart';
import 'secondary_index/index_size_event.dart';
import 'secondary_index/index_spec.dart';
import 'secondary_index/secondary_index.dart';
import 'snapshot/snapshot.dart' show encodeSnapshot, SnapshotMeta;
import 'string_interner.dart';
import 'transaction.dart';
import 'wal_op.dart';
import 'wal_sink.dart';

/// Public facade over the engine.
///
/// Hosts the read API, the transaction surface, and the WAL/durability
/// wiring. The read API is the locked design: the **primitive range**
/// layer is the core, with a callback-based "for each" sugar layer on
/// top.
class GraphDb {
  final MutableGraphState _state;

  /// Optional WAL sink. When non-null, every committed
  /// transaction's sequenced ops are appended through this sink with
  /// [Durability.fsync] before the applicator mutates state. When
  /// null, the engine runs purely in-memory (tests + the read-only
  /// fixture flow).
  final WalSink? _sink;

  /// `InternString` ops queued between transactions, flushed at the
  /// front of the next commit so recovery sees the catalog growth in
  /// the order it was applied.
  final List<InternString> _pendingInterns = [];

  /// Schema ops (`DeclareColumn` / `DeclareIndex` / `DropIndex`) queued
  /// between transactions. Flushed after [_pendingInterns] — a column or
  /// index declaration names a keyId, so the intern that minted it must
  /// be sequenced first — and before the transaction's own ops, so a
  /// write into a freshly-declared column replays in the right order.
  final List<WalOp> _pendingSchemaOps = [];

  /// Set by the first [close] call. Guards against double-close: a
  /// second `close()` re-invoking the underlying sink's `close()` is not
  /// guaranteed idempotent, so we make it a no-op here instead.
  bool _closed = false;

  /// Invoked synchronously after each successful commit (after the
  /// overlay-merge check, while the just-committed state is applied).
  ///
  /// Internal-collaborator hook — `graph_db_wal`'s auto-checkpoint
  /// coordinator registers here to observe write activity. Keep the
  /// callback cheap and schedule any heavy work (snapshot I/O)
  /// asynchronously; it runs on the commit path. Setting it replaces any
  /// prior callback; `null` clears it.
  void Function()? afterCommit;

  GraphDb._(this._state, [this._sink]);

  /// Wraps an already-built [MutableGraphState]. Fixture loaders (e.g.
  /// `SocialGraph.build()` from `package:graph_db_core/samples.dart`)
  /// hand back a [GraphDb] this way.
  ///
  /// Pass [sink] to enable WAL writes on commit. The sink
  /// is closed by [close]. `graph_db_wal`'s `WalWriter` is the
  /// production-grade implementation.
  factory GraphDb.fromState(MutableGraphState state, {WalSink? sink}) =>
      GraphDb._(state, sink);

  /// True once [close] has run. Writes are refused from this point on;
  /// reads keep working against the final in-memory state.
  bool get isClosed => _closed;

  /// Closes the engine: flushes any pending `InternString` ops as a
  /// final empty-but-not-quite commit (if a sink is configured), then
  /// closes the sink.
  ///
  /// **Idempotent** — the second and later calls are no-ops and return
  /// without touching the sink. Returns immediately once closed.
  ///
  /// After close, [runTransaction] and [bulkAddEdges] throw
  /// [StateError]. They used to fail only at the sink layer, which meant
  /// an in-memory engine (no sink) silently accepted writes that could
  /// never be persisted.
  Future<void> close() async {
    // Set before the first `await` so a second (concurrent, un-awaited)
    // close returns immediately rather than double-closing the sink.
    if (_closed) return;
    _closed = true;
    if (_sink != null &&
        (_pendingInterns.isNotEmpty || _pendingSchemaOps.isNotEmpty)) {
      // Flush pending interns + schema ops so they land in the WAL with proper
      // Begin/Commit framing. Use `fsync` so the close-time data is
      // durable before the sink shuts down — group-commit's deferred ack
      // would otherwise race with `close`. Goes straight to `_commit`
      // rather than through `runTransaction`, whose closed-engine guard
      // would (correctly) refuse this write.
      final txn = Transaction(_state.allocTxnId(), _state);
      _terminate(txn);
      await _commit(txn, Durability.fsync);
    }
    await _sink?.close();
  }

  void _rejectIfClosed(String op) {
    if (_closed) {
      throw StateError('$op after close() — the engine is closed');
    }
  }

  // ---------------------------------------------------------------- catalog
  //
  // Sync — the WAL is not touched here. Newly-interned strings are
  // queued in [_pendingInterns] and prepended to the next transaction
  // commit so recovery agrees on ids before any op references them.

  int internLabel(String name) => _internInto(
        existing: _state.strings.labelIdOf(name),
        intern: _state.strings.internLabel,
        kind: StringKind.label,
        value: name,
      );

  int internEdgeType(String name) => _internInto(
        existing: _state.strings.edgeTypeIdOf(name),
        intern: _state.strings.internEdgeType,
        kind: StringKind.edgeType,
        value: name,
      );

  int internPropKey(String name) => _internInto(
        existing: _state.strings.propKeyIdOf(name),
        intern: _state.strings.internPropKey,
        kind: StringKind.propKey,
        value: name,
      );

  int _internInto({
    required int? existing,
    required int Function(String) intern,
    required StringKind kind,
    required String value,
  }) {
    if (existing != null) return existing;
    final id = intern(value);
    if (_sink != null) {
      _pendingInterns.add(InternString(
        intId: id,
        value: value,
        kind: kind,
      ));
    }
    return id;
  }

  String? labelName(int id) => _state.strings.labelOf(id);
  String? edgeTypeName(int id) => _state.strings.edgeTypeOf(id);
  String? propKeyName(int id) => _state.strings.propKeyOf(id);

  /// Number of interned property keys. Catalog introspection for
  /// exporters that enumerate the key space (e.g. the sync engine).
  int get propKeyCount => _state.strings.propKeyCount;

  // Non-interning name → id resolvers. Unlike [internLabel] etc., these
  // never create a new catalog entry (and never touch the WAL): they
  // return the existing id or `null`. Use them to read by name without
  // polluting the catalog with keys that don't exist yet — e.g.
  // `final k = db.propKeyId('name'); if (k != null) db.getNodeStringProp(v, k);`
  int? labelId(String name) => _state.strings.labelIdOf(name);
  int? edgeTypeId(String name) => _state.strings.edgeTypeIdOf(name);
  int? propKeyId(String name) => _state.strings.propKeyIdOf(name);

  /// `_state`, guarded for in-transaction reads (**snapshot-at-start**).
  /// The high-level data-read API routes through this. Before the active
  /// txn's first write, reads return the committed-as-of-begin state.
  /// After a write, a read throws — a buffer-only txn would otherwise
  /// silently observe pre-write state (no read-your-writes). The
  /// allocation-free primitive range API and the catalog/schema lookups
  /// use `_state` directly and are exempt.
  MutableGraphState get _r {
    if (_state.activeTxnId != null && _state.activeTxnHasWrites) {
      throw StateError(
        'read issued after a write in the same runTransaction body: the '
        'transaction is buffer-only, so this would return pre-write state. '
        'Move the read before the first mutation, or split the transaction. '
        '(Reads before the first write see the committed-as-of-begin '
        'snapshot.)',
      );
    }
    return _state;
  }

  /// Narrow, read-only window onto committed graph state — the seam the
  /// GQL package reads through instead of the engine state. See
  /// [GraphReadView].
  ///
  /// **Different visibility rules from the rest of this class.**
  /// Deliberately unguarded (backed by `_state`, not `_r`): a
  /// `MATCH … SET` has to evaluate a read-dependent right-hand side while
  /// its own mutations sit buffered in the same transaction, which the
  /// public read API refuses to do. So inside a transaction, `db.nodeCount`
  /// throws after the first write while `db.readView` keeps answering from
  /// the committed-as-of-begin state. Outside a transaction the two agree.
  /// Prefer the guarded surface unless you are writing an executor.
  GraphReadView get readView => _state;

  // -------------------------------------------------------------- topology

  /// Total node count. **Read-your-writes:** committed mutations are
  /// reflected immediately — no `mergeNow()` required. Matches the
  /// post-merge count exactly; deleted vids retain their slot (ids are
  /// never reused), so this can exceed the number of live logical nodes.
  int get nodeCount => _r.effectiveNodeCount;

  /// Total edge count. Read-your-writes — committed adds and removals are
  /// reflected immediately, with no `mergeNow()`.
  int get edgeCount => _r.effectiveEdgeCount;

  /// Out-degree of [vid]. Read-your-writes (overlay-aware): O(1) on a
  /// clean overlay, O(degree) while writes are pending.
  int outDegree(Vid vid) => _r.effectiveOutDegree(vid);

  /// In-degree of [vid]. Read-your-writes — see [outDegree].
  int inDegree(Vid vid) => _r.effectiveInDegree(vid);

  /// True when committed mutations are sitting in the overlay, not yet
  /// folded into the CSR. The read API is read-your-writes regardless, so
  /// this is purely observability: it lets callers of the
  /// snapshot-semantics primitive range API (see below) tell when the CSR
  /// is stale relative to committed writes. Always `false` immediately
  /// after [mergeNow].
  bool get hasPendingWrites => !_state.overlay.isEmpty;

  /// Forces an overlay merge into the CSR now. Normally unnecessary —
  /// commits merge on a threshold — but snapshot/export paths call it to
  /// work against a clean, overlay-empty base.
  void mergeNow() => _state.mergeNow();

  /// Encodes the current state as a snapshot (bytes + metadata). Requires
  /// an empty overlay — call [mergeNow] first. Used by the WAL checkpoint
  /// path so the snapshot codec stays internal to the facade.
  ({Uint8List bytes, SnapshotMeta meta}) captureSnapshot() =>
      encodeSnapshot(_state);

  /// True iff [vid] carries [labelId]. Overlay-aware. Allocation-free
  /// O(log k) where k is per-vid label count.
  bool hasLabel(Vid vid, int labelId) =>
      _r.hasLabelEffective(vid, labelId);

  /// Full label-id set carried by [vid]. Overlay-aware. The returned
  /// iterable is a view — do not mutate.
  Iterable<int> labelsOf(Vid vid) => _r.effectiveLabelsOf(vid);

  /// True iff [vid] is a live (non-deleted) node. Overlay-aware.
  /// Exporters (e.g. the sync engine) use this to skip tombstoned slots.
  bool isNodeVisible(Vid vid) => _r.isNodeVisible(vid);

  // ------------------------------------------------------------- traversal
  // Primitive range API — allocation-free, fastest on AOT.
  //
  // **Snapshot semantics — NOT read-your-writes.** These index directly
  // into the CSR arrays, which reflect only the last merge; overlay-
  // resident edges (committed but not yet folded into the CSR) are
  // invisible here. This is the deliberate exception to the engine's
  // read-your-writes contract — the price of the zero-allocation
  // guarantee. For read-your-writes traversal use [forEachOutNeighbor] /
  // [forEachInNeighbor], or call [mergeNow] first.
  // [hasPendingWrites] reports when the CSR is stale relative to writes.

  int outRangeStart(Vid vid) => _state.outStart(vid);
  int outRangeEnd(Vid vid) => _state.outEnd(vid);
  Vid outNeighborAt(int i) => _state.outNeighborAt(i);
  Eid edgeIdAt(int i) => _state.edgeIdAt(i);
  int edgeTypeAt(int i) => _state.edgeTypeAt(i);

  int inRangeStart(Vid vid) => _state.inStart(vid);
  int inRangeEnd(Vid vid) => _state.inEnd(vid);
  Vid inNeighborAt(int i) => _state.inNeighborAt(i);
  Eid inEdgeIdAt(int i) => _state.inEdgeIdAt(i);
  int inEdgeTypeAt(int i) => _state.inEdgeTypeAt(i);

  /// Callback sugar — invokes [visit] for each out-edge of [vid].
  ///
  /// **Read-your-writes** (overlay-aware): committed edges are visited
  /// immediately, removed edges and edges to deleted nodes are skipped,
  /// with no `mergeNow()`. The inner loop is allocation-free; this wrapper
  /// allocates one adapter closure per call. For the strictly
  /// allocation-free, snapshot-of-last-merge hot path use the primitive
  /// range API ([outRangeStart] / [outRangeEnd] / [outNeighborAt]).
  void forEachOutNeighbor(
    Vid vid,
    void Function(Vid dst, Eid eid, int edgeType) visit,
  ) {
    _r.forEachOutEdge(
      vid,
      (eid, dst, edgeType) => visit(dst, eid, edgeType),
    );
  }

  /// Callback sugar — invokes [visit] for each in-edge of [vid].
  /// Read-your-writes (overlay-aware) — see [forEachOutNeighbor].
  void forEachInNeighbor(
    Vid vid,
    void Function(Vid src, Eid eid, int edgeType) visit,
  ) {
    _r.forEachInEdge(
      vid,
      (eid, src, edgeType) => visit(src, eid, edgeType),
    );
  }

  // ---------------------------------------------------------------- labels

  /// All vids carrying [labelId], in ascending order. **Read-your-writes:**
  /// committed mutations are reflected immediately — no `mergeNow()`
  /// required. When no writes are pending the returned [Uint32List] is a
  /// zero-copy view into the pre-built CSR index; when the overlay is
  /// dirty it is a freshly-sorted copy folding in overlay-added nodes and
  /// label changes. Either way, do not mutate it.
  Uint32List labelScan(int labelId) => _r.effectiveLabelScan(labelId);

  /// All vids carrying [labelId] as typed [Vid]s, ascending. The
  /// ergonomic companion to [labelScan] — a **lazy view** over the same
  /// index, so iterating it costs no copy of the underlying `Uint32List`
  /// (each [Vid] is a zero-cost wrap of the int). Read-your-writes, same
  /// as [labelScan]. Use [labelScan] directly for the allocation-free
  /// indexed hot path.
  ///
  /// ```dart
  /// for (final v in db.labelScanVids(person)) {
  ///   print(db.getNodeStringProp(v, name)); // v is a Vid — no Vid(..) wrap
  /// }
  /// ```
  Iterable<Vid> labelScanVids(int labelId) =>
      _r.effectiveLabelScan(labelId).map(Vid.new);

  // --------------------------------------------------------- property reads
  //
  // Raw primitives — caller knows the type (`columnType` on the
  // property store) or guards via [hasNodeProp] / [nodePropIsNull].
  // Use [getNodeProp] / [getEdgeProp] for the boxed boundary form.

  bool hasNodeProp(Vid vid, int keyId) => _r.hasNodeProp(vid, keyId);
  bool nodePropIsNull(Vid vid, int keyId) =>
      _r.nodeProps.isNull(vid.value, keyId);
  ColumnType? nodePropType(int keyId) =>
      _state.nodeProps.columnType(keyId); // schema lookup — exempt

  int getNodeIntProp(Vid vid, int keyId) =>
      _r.getNodeIntProp(vid, keyId);
  double getNodeDoubleProp(Vid vid, int keyId) =>
      _r.getNodeDoubleProp(vid, keyId);
  bool getNodeBoolProp(Vid vid, int keyId) =>
      _r.getNodeBoolProp(vid, keyId);
  String getNodeStringProp(Vid vid, int keyId) =>
      _r.getNodeStringProp(vid, keyId);

  bool hasEdgeProp(Eid eid, int keyId) => _r.hasEdgeProp(eid, keyId);
  ColumnType? edgePropType(int keyId) =>
      _state.edgeProps.columnType(keyId); // schema lookup — exempt

  int getEdgeIntProp(Eid eid, int keyId) =>
      _r.getEdgeIntProp(eid, keyId);
  String getEdgeStringProp(Eid eid, int keyId) =>
      _r.getEdgeStringProp(eid, keyId);

  /// Boundary read — constructs and returns a [PropValue]. Allocates;
  /// use the typed primitive accessors above on the hot path.
  PropValue? getNodeProp(Vid vid, int keyId) =>
      _r.nodeProps.getBoxed(vid.value, keyId);
  PropValue? getEdgeProp(Eid eid, int keyId) =>
      _r.edgeProps.getBoxed(eid.value, keyId);

  // --------------------------------------------------------------- lookups
  //
  // Convenience finders over the read-your-writes scan — they save the
  // `labelScan` + per-vid compare boilerplate consumers otherwise write
  // by hand. O(n) in the labelled set, which suits the small-to-medium
  // graphs this engine targets; for large, equality-heavy workloads build
  // a secondary index ([createNodePropertyIndex]) and query it directly.

  /// First node whose [keyId] property equals [value], or `null` if none.
  ///
  /// Pass [label] to scan only nodes carrying that label; omit it to scan
  /// every node. **Read-your-writes** — committed mutations are seen
  /// immediately. An absent or NULL property never matches a non-null
  /// [value]. For lookup by a unique id, prefer the O(1)
  /// [nodeByLogicalId].
  ///
  /// Allocation-free per candidate: the column type is resolved once and
  /// the comparison reads the raw typed slot. It used to box every row
  /// into a `PropValue` just to `==` it, which cost one allocation per
  /// node scanned.
  Vid? findNodeByProp(int keyId, PropValue value, {int? label}) {
    final s = _r;
    final match = _rawMatcher(s.nodeProps, keyId, value);
    if (match == null) return null; // type mismatch — nothing can match
    if (label != null) {
      for (final raw in s.effectiveLabelScan(label)) {
        if (match(raw)) return Vid(raw);
      }
      return null;
    }
    final n = s.nextVid;
    for (var v = 0; v < n; v++) {
      if (match(v)) return Vid(v);
    }
    return null;
  }

  /// Every node whose [keyId] property equals [value], ascending by vid.
  /// Pass [label] to restrict to that label. Read-your-writes — see
  /// [findNodeByProp].
  List<Vid> findNodesByProp(int keyId, PropValue value, {int? label}) {
    final s = _r;
    final out = <Vid>[];
    final match = _rawMatcher(s.nodeProps, keyId, value);
    if (match == null) return out;
    if (label != null) {
      for (final raw in s.effectiveLabelScan(label)) {
        if (match(raw)) out.add(Vid(raw));
      }
    } else {
      final n = s.nextVid;
      for (var v = 0; v < n; v++) {
        if (match(v)) out.add(Vid(v));
      }
    }
    return out;
  }

  /// Builds an `id -> bool` equality test against the raw column for
  /// [keyId], or `null` when [value]'s type can't match the column's (so
  /// the caller can skip the scan entirely).
  ///
  /// Each returned closure re-checks `has(id, keyId)` so an absent or
  /// explicitly-NULL slot never matches a non-null [value] — the same
  /// contract the boxed comparison had.
  bool Function(int id)? _rawMatcher(
    PropertyStore store,
    int keyId,
    PropValue value,
  ) {
    final type = store.columnType(keyId);
    if (type == null) return null; // no column — no row can match
    switch (value) {
      case PropInt(value: final q):
        if (type == ColumnType.int_) {
          return (id) => store.has(id, keyId) && store.getInt(id, keyId) == q;
        }
        // `stringId` columns hold interned ids, compared as ints — this
        // mirrors what the boxed form did for a PropInt query.
        if (type == ColumnType.stringId) {
          return (id) =>
              store.has(id, keyId) && store.getStringId(id, keyId) == q;
        }
        return null;
      case PropDouble(value: final q):
        if (type != ColumnType.double_) return null;
        return (id) => store.has(id, keyId) && store.getDouble(id, keyId) == q;
      case PropBool(value: final q):
        if (type != ColumnType.bool_) return null;
        return (id) => store.has(id, keyId) && store.getBool(id, keyId) == q;
      case PropString(value: final q):
        if (type != ColumnType.string) return null;
        return (id) => store.has(id, keyId) && store.getString(id, keyId) == q;
      case PropNull():
        // Matches a slot that is present but explicitly NULL.
        return (id) => store.has(id, keyId) && store.isNull(id, keyId);
      case PropList():
      case PropMap():
        // Never storable in a typed column, so never findable.
        return null;
    }
  }

  // ------------------------------------------------------------- logical id
  //
  // Every node carries a `logicalId` (the UUIDv7 minted by `addNode`, or
  // the value you passed). The engine maintains a unique index over it,
  // so there's no need to invent your own `extId` property + secondary
  // index for stable-id lookups.

  /// The logicalId of [vid] — null if it has none (e.g. a fixture node)
  /// or was deleted. **Read-your-writes.**
  String? getNodeLogicalId(Vid vid) => _r.logicalIdOf(vid.value);

  /// The node currently holding [logicalId], or null. O(1) via the
  /// built-in unique index. **Read-your-writes** — a node committed this
  /// turn resolves immediately. logicalId is unique: adding a node with a
  /// duplicate logicalId throws [ConstraintViolation].
  Vid? nodeByLogicalId(String logicalId) {
    final v = _r.vidOfLogicalId(logicalId);
    return v == null ? null : Vid(v);
  }

  // ----- Transactions --------------------

  /// Runs [body] inside a transaction.
  ///
  /// On normal return, commits: the buffered ops are sealed into a
  /// `BeginTxn` → ops → `CommitTxn` stream (LSNs assigned in order),
  /// then routed through the applicator. The return value is forwarded
  /// to the caller.
  ///
  /// On any throw, rolls back: the buffer is dropped and the state
  /// is untouched. **Allocated vids / eids are still consumed** —
  /// (ids never reused). The exception propagates.
  ///
  /// Single-writer model: nested + concurrent
  /// `runTransaction` calls throw [StateError].
  ///
  /// Empty transactions (body queued no ops) are skipped — no `BeginTxn`
  /// / `CommitTxn` are emitted, no LSNs consumed.
  /// [durability] — per-call override of the engine default
  ///. Defaults to [Durability.group]: this commit lands
  /// in the next group-fsync window (1 ms by default). Pass
  /// [Durability.fsync] for a per-commit fsync. Tests that want to
  /// avoid the group-window wait can pass [Durability.fsync] or
  /// [Durability.none].
  ///
  /// [capturePrevValues] — when `true`, `setNodeProp` / `setEdgeProp`
  /// inside the txn auto-capture the current value into the WAL op's
  /// `prevValue` field. Off by default — each capture costs a `getBoxed`
  /// allocation. Enable for audit trails or simpler sync conflict
  /// detection.
  Future<T> runTransaction<T>(
    FutureOr<T> Function(Transaction txn) body, {
    Durability durability = Durability.group,
    bool capturePrevValues = false,
  }) async {
    _rejectIfClosed('runTransaction');
    if (_state.activeTxnId != null) {
      throw StateError(
          'a transaction (txnId=${_state.activeTxnId}) is already in '
          'flight — the engine is single-writer');
    }
    final txnId = _state.allocTxnId();
    _state.activeTxnId = txnId;
    _state.activeTxnHasWrites = false; // reads-before-write see committed state
    final txn = Transaction(
      txnId,
      _state,
      capturePrevValues: capturePrevValues,
      internLabel: internLabel,
      internEdgeType: internEdgeType,
      internPropKey: internPropKey,
    );
    try {
      final result = await body(txn);
      await _commit(txn, durability);
      return result;
    } catch (_) {
      // Rollback: drop the buffer. Allocated vids/eids are NOT
      // released monotonic identity.
      rethrow;
    } finally {
      _terminate(txn);
      _state.activeTxnId = null;
      _state.activeTxnHasWrites = false;
    }
  }

  Future<void> _commit(Transaction txn, Durability durability) async {
    // Skip empty txn only when there is no queued schema growth either —
    // otherwise we still need to flush it.
    if (txn.bufferedOps.isEmpty &&
        _pendingInterns.isEmpty &&
        _pendingSchemaOps.isEmpty) {
      return;
    }
    final ops = <SequencedWalOp>[];
    final beginLsn = _state.allocLsn();
    ops.add(SequencedWalOp(
      lsn: beginLsn,
      txnId: txn.txnId,
      op: const BeginTxn(),
    ));
    // InternString catalog ops first so any user op that references a
    // new keyId / labelId is sequenced after its declaration.
    for (final op in _pendingInterns) {
      ops.add(SequencedWalOp(
        lsn: _state.allocLsn(),
        txnId: txn.txnId,
        op: op,
      ));
    }
    // Then schema declarations, which reference those ids.
    for (final op in _pendingSchemaOps) {
      ops.add(SequencedWalOp(
        lsn: _state.allocLsn(),
        txnId: txn.txnId,
        op: op,
      ));
    }
    for (final op in txn.bufferedOps) {
      ops.add(SequencedWalOp(
        lsn: _state.allocLsn(),
        txnId: txn.txnId,
        op: op,
      ));
    }
    final commitLsn = _state.allocLsn();
    ops.add(SequencedWalOp(
      lsn: commitLsn,
      txnId: txn.txnId,
      op: CommitTxn(commitLsn),
    ));
    // Durability gate: write to the WAL first. If the sink throws,
    // state is left unchanged (the txn effectively rolls back). The
    // sink coalesces the per-op fsync into a single durability ack
    // per the requested mode.
    if (_sink != null) {
      await _sink.appendBatch(ops, durability: durability);
    }
    // InternString and schema ops were already applied eagerly (the
    // string is in the local interner; the column / index exists). Skip
    // them on apply — re-applying an intern trips the CorruptionDetected
    // mismatch guard, and re-applying a DeclareIndex would rebuild an
    // index that is already correct.
    for (final seq in ops) {
      if (seq.op is InternString ||
          seq.op is DeclareColumn ||
          seq.op is DeclareIndex ||
          seq.op is DropIndex) {
        continue;
      }
      apply(_state, seq, recovery: false);
    }
    _pendingInterns.clear();
    _pendingSchemaOps.clear();
    // After applying, check the overlay merge threshold. Uses the
    // worker isolate when a coordinator is wired, otherwise falls back
    // to the synchronous main-isolate fold.
    await _state.maybeMergeOverlayAsync();
    // Post-commit hook (auto-checkpoint coordinator). Fires only on a
    // real commit — the early-return above skips empty no-op txns.
    afterCommit?.call();
  }

  void _terminate(Transaction txn) {
    if (!txn.isTerminated) {
      markTransactionTerminated(txn);
    }
  }

  // ----- observable LSN -----
  /// LSN of the most recently applied op. Foundation for snapshot
  /// isolation — readers can capture this and later compare to know
  /// whether the engine has advanced. Full pinning + MVCC enforcement
  /// is a future layer.
  int get currentLsn => _state.nextLsn - 1;

  /// Current next-LSN — the LSN the next committed op will receive.
  int get nextLsn => _state.nextLsn;

  /// Active pins on this engine.
  ///
  /// **Observational only.** Nothing in the engine reads this set to gate
  /// anything: there is no MVCC, and a pin does not stop the overlay from
  /// merging or a version from being overwritten. It exists so the API
  /// shape is in place for that work.
  final Set<LsnPin> _activePins = {};
  int get activePinCount => _activePins.length;

  /// Captures the current LSN as a [LsnPin] — see [LsnPin] /
  /// [IsolationLevel] for v1 semantics.
  ///
  /// A pin holds no version and blocks nothing (see [_activePins]); it
  /// records an LSN you can compare later. Call `pin.release()` when done
  /// — not because anything is retained on your behalf, but because an
  /// unreleased pin stays in the set and [activePinCount] drifts upward
  /// for the life of the engine.
  LsnPin pinLsn({
    IsolationLevel isolation = IsolationLevel.snapshot,
  }) {
    late LsnPin pin;
    pin = LsnPin(
      lsn: currentLsn,
      isolation: isolation,
      onRelease: () => _activePins.remove(pin),
    );
    _activePins.add(pin);
    return pin;
  }

  // constraint catalog
  /// Read-only handle to the engine's constraint catalog. Application
  /// code reads this to introspect active constraints; declare /
  /// drop go through `runTransaction` so the WAL records them and
  /// recovery rebuilds the catalog.
  ConstraintCatalog get constraints => _state.constraints;

  // ----- Bulk write path -------------------------------

  /// Bulk edge import — bypasses the overlay and rebuilds the CSR
  /// directly with the new edges folded in. Single WAL transaction
  /// covers the whole batch. Returns the allocated eids in input
  /// order.
  ///
  /// Use over a `runTransaction` loop when importing > a few thousand
  /// edges: the overlay path would trip the merge threshold mid-batch
  /// and pay multiple full-CSR rebuilds; this path pays exactly one.
  ///: "100k bulk-import in < 1s".
  ///
  /// **Properties are not supported in this path** — bulk insert is the
  /// happy path for topology import. Call `runTransaction` for any
  /// edges that carry properties.
  Future<List<Eid>> bulkAddEdges(
    List<BulkEdge> edges, {
    Durability durability = Durability.group,
  }) async {
    _rejectIfClosed('bulkAddEdges');
    if (_state.activeTxnId != null) {
      throw StateError(
          'cannot bulkAddEdges while txnId=${_state.activeTxnId} is in '
          'flight');
    }
    if (edges.isEmpty) return const [];
    final txnId = _state.allocTxnId();
    _state.activeTxnId = txnId;
    _state.activeTxnHasWrites = true; // bulk write — reads must still throw
    try {
      // 1. Endpoint validation up front — fail fast before allocating.
      for (final e in edges) {
        if (!_state.isNodeVisible(e.src)) {
          throw NotFoundException(
              'bulkAddEdges: src vid ${e.src.value} does not exist');
        }
        if (!_state.isNodeVisible(e.dst)) {
          throw NotFoundException(
              'bulkAddEdges: dst vid ${e.dst.value} does not exist');
        }
      }

      // 2. Allocate eids + logical ids.
      final eids = <Eid>[for (var i = 0; i < edges.length; i++) _state.allocEid()];
      final logicalIds = [
        for (final e in edges) e.logicalId ?? newUuidV7(),
      ];

      // 3. Build WAL stream. Catalog interns flush at the front so
      //    recovery sees them before any op references the new ids.
      final ops = <SequencedWalOp>[];
      ops.add(SequencedWalOp(
        lsn: _state.allocLsn(),
        txnId: txnId,
        op: const BeginTxn(),
      ));
      for (final intern in _pendingInterns) {
        ops.add(SequencedWalOp(
          lsn: _state.allocLsn(),
          txnId: txnId,
          op: intern,
        ));
      }
      for (final op in _pendingSchemaOps) {
        ops.add(SequencedWalOp(
          lsn: _state.allocLsn(),
          txnId: txnId,
          op: op,
        ));
      }
      for (var i = 0; i < edges.length; i++) {
        final e = edges[i];
        ops.add(SequencedWalOp(
          lsn: _state.allocLsn(),
          txnId: txnId,
          op: AddEdge(
            eid: eids[i],
            logicalId: logicalIds[i],
            src: e.src,
            dst: e.dst,
            typeId: e.typeId,
            props: const {},
          ),
        ));
      }
      final commitLsn = _state.allocLsn();
      ops.add(SequencedWalOp(
        lsn: commitLsn,
        txnId: txnId,
        op: CommitTxn(commitLsn),
      ));

      // 4. WAL write (durability gate).
      if (_sink != null) {
        await _sink.appendBatch(ops, durability: durability);
      }
      _pendingInterns.clear();
      _pendingSchemaOps.clear();

      // 5. Apply: fold any pending overlay into the CSR first so the
      //    bulk addition sits on a clean base, then build a temporary
      //    single-purpose overlay carrying just the bulk edges and
      //    fold that in.
      if (!_state.overlay.isEmpty) _state.mergeNow();
      final tmp = DeltaOverlay();
      for (var i = 0; i < edges.length; i++) {
        final e = edges[i];
        tmp.recordAddEdge(
          AddedEdge(
            logicalId: logicalIds[i],
            src: e.src.value,
            dst: e.dst.value,
            typeId: e.typeId,
          ),
          eids[i].value,
        );
      }
      final fresh = foldOverlayIntoCsr(base: _state.csr, overlay: tmp);
      _state.installMergedCsr(fresh);

      // Post-commit hook, same as `_commit`. Omitting it here meant the
      // one path that grows the WAL fastest was invisible to the
      // auto-checkpoint coordinator, so a bulk import never triggered a
      // checkpoint however large it was.
      afterCommit?.call();

      return eids;
    } finally {
      _state.activeTxnId = null;
      // Reset alongside `activeTxnId`. Leaving it set relied on the next
      // `runTransaction` clearing it — true today, but the read guard
      // reads both flags and they should never disagree.
      _state.activeTxnHasWrites = false;
    }
  }

  // ----- Secondary indexes -------------------------------------

  /// Soft-budget size-event hook. Default unset = silent.
  /// Wire a logger or a test assertion sink here to be notified when
  /// a freshly-built index crosses the [kIndexSizeWarnThreshold]
  /// ratio of [Csr.sizeBytes]. Fired once per `createIndex()`.
  IndexSizeListener? onIndexSizeEvent;

  /// Defines the catalog schema in one call and returns a reusable
  /// [GraphSchema] handle: interns [labels], [edgeTypes], and [propKeys],
  /// and reserves a typed node column for each declared prop key (so the
  /// type is known before any write). The documented ergonomic entry
  /// point; the string-keyed `txn.*Named` methods are the zero-setup
  /// on-ramp.
  ///
  /// Non-transactional — interning and column declaration are direct
  /// schema ops, journaled with the next commit rather than wrapped in one.
  /// Both survive a restart, so calling this again after reopening is
  /// optional: a re-declaration matching the persisted type no-ops, a
  /// conflicting one throws [ConstraintViolation] (the type-lock guard).
  GraphSchema defineSchema({
    Set<String> labels = const {},
    Set<String> edgeTypes = const {},
    Map<String, ColumnType> propKeys = const {},
  }) =>
      GraphSchema(this,
          labels: labels, edgeTypes: edgeTypes, propKeys: propKeys);

  /// Declares a node-property column for [keyId] with [type] ahead of any
  /// write, so the type is known before data exists — typed reads, the
  /// finders, and [createNodePropertyIndex] can bind to an empty column.
  /// Idempotent when the type matches; throws [ConstraintViolation] if
  /// [keyId] already carries a column of a different type (the type-lock
  /// guard).
  ///
  /// **Journaled** — the declaration is recorded in the WAL, so the
  /// type-lock survives a restart and there is no need to re-declare on
  /// each open. Applies immediately; the WAL record is flushed with the
  /// next commit (or by [close]), like an intern.
  void declareNodeColumn(int keyId, ColumnType type) =>
      _declareColumn(PropertyOwner.node, keyId, type);

  /// Edge-store counterpart of [declareNodeColumn].
  void declareEdgeColumn(int keyId, ColumnType type) =>
      _declareColumn(PropertyOwner.edge, keyId, type);

  void _declareColumn(PropertyOwner owner, int keyId, ColumnType type) {
    _rejectIfClosed('declareColumn');
    // Apply first so a conflicting type throws before anything is
    // journaled.
    _state.applyDeclareColumn(owner, keyId, type);
    if (_sink != null) {
      _pendingSchemaOps
          .add(DeclareColumn(owner: owner, keyId: keyId, type: type));
    }
  }

  /// Builds a node-property index from the current state. Fires
  /// [onIndexSizeEvent] if the new index is at or above the soft
  /// budget.
  ///
  /// **Journaled** — the declaration is recorded in the WAL and the index
  /// is rebuilt from recovered data on the next open, so it no longer has
  /// to be re-created by hand after a restart. Index *contents* are
  /// derived and are not written to the log.
  ///
  /// The default (non-incremental, non-deferred) index is rebuilt on
  /// every write that touches its key; see [IndexSpec] for the
  /// incremental and deferred variants.
  SecondaryIndex createNodePropertyIndex(IndexSpec spec) =>
      _createIndex(PropertyOwner.node, spec);

  /// Builds an edge-property index from the current state. See
  /// [createNodePropertyIndex] for semantics.
  SecondaryIndex createEdgePropertyIndex(IndexSpec spec) =>
      _createIndex(PropertyOwner.edge, spec);

  SecondaryIndex _createIndex(PropertyOwner owner, IndexSpec spec) {
    _rejectIfClosed('createPropertyIndex');
    final idx = owner == PropertyOwner.node
        ? _state.createNodePropertyIndex(spec, onSizeEvent: onIndexSizeEvent)
        : _state.createEdgePropertyIndex(spec, onSizeEvent: onIndexSizeEvent);
    if (_sink != null) {
      _pendingSchemaOps.add(DeclareIndex(owner: owner, spec: spec));
    }
    return idx;
  }

  /// Looks up a registered node-property index by name.
  SecondaryIndex? getNodeIndex(String name) => _state.getNodeIndex(name);

  /// Looks up a registered edge-property index by name.
  SecondaryIndex? getEdgeIndex(String name) => _state.getEdgeIndex(name);

  /// Removes a node-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed. Journaled, so the
  /// drop survives a restart.
  SecondaryIndex? dropNodeIndex(String name) =>
      _dropIndex(PropertyOwner.node, name);

  /// Removes an edge-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropEdgeIndex(String name) =>
      _dropIndex(PropertyOwner.edge, name);

  SecondaryIndex? _dropIndex(PropertyOwner owner, String name) {
    _rejectIfClosed('dropPropertyIndex');
    final removed = owner == PropertyOwner.node
        ? _state.dropNodeIndex(name)
        : _state.dropEdgeIndex(name);
    if (removed != null && _sink != null) {
      _pendingSchemaOps.add(DropIndex(owner: owner, name: name));
    }
    return removed;
  }
}
