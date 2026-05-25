import 'dart:async';
import 'dart:typed_data';

import 'applicator.dart';
import 'bulk_edge.dart';
import 'constraints/constraint_catalog.dart';
import 'csr.dart';
import 'durability.dart';
import 'exceptions.dart';
import 'identity/uuid_v7.dart';
import 'ids.dart';
import 'isolation.dart';
import 'merge/merge_fold.dart';
import 'mutable_graph_state.dart';
import 'overlay/delta_overlay.dart';
import 'prop_value.dart';
import 'property_store.dart';
import 'secondary_index/index_size_event.dart';
import 'secondary_index/index_spec.dart';
import 'secondary_index/secondary_index.dart';
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

  /// Closes the engine: flushes any pending `InternString` ops as a
  /// final empty-but-not-quite commit (if a sink is configured), then
  /// closes the sink.
  ///
  /// **Idempotent** — the second and later calls are no-ops and return
  /// without touching the sink. After close, commit attempts still fail
  /// at the sink layer. Returns immediately once closed.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_sink != null && _pendingInterns.isNotEmpty) {
      // Flush pending interns through an empty user-op txn so they
      // land in the WAL with proper Begin/Commit framing. Use
      // `fsync` so the close-time data is durable before the sink
      // shuts down — group-commit's deferred ack would otherwise
      // race with `close`.
      await runTransaction((_) {}, durability: Durability.fsync);
    }
    await _sink?.close();
  }

  /// Underlying state — for advanced callers and tests.
  MutableGraphState get state => _state;

  /// CSR — exposed so callers writing extremely tight loops can index
  /// the typed arrays directly.
  Csr get csr => _state.csr;

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

  // Non-interning name → id resolvers. Unlike [internLabel] etc., these
  // never create a new catalog entry (and never touch the WAL): they
  // return the existing id or `null`. Use them to read by name without
  // polluting the catalog with keys that don't exist yet — e.g.
  // `final k = db.propKeyId('name'); if (k != null) db.getNodeStringProp(v, k);`
  int? labelId(String name) => _state.strings.labelIdOf(name);
  int? edgeTypeId(String name) => _state.strings.edgeTypeIdOf(name);
  int? propKeyId(String name) => _state.strings.propKeyIdOf(name);

  /// `_state`, guarded against in-transaction reads. The high-level
  /// data-read API routes through this so a read issued inside a
  /// `runTransaction` body — which would silently observe pre-commit
  /// state (the txn is buffer-only) — throws instead of misleading the
  /// caller. The allocation-free primitive range API and the
  /// catalog/schema lookups use `_state` directly and are exempt.
  MutableGraphState get _r {
    if (_state.activeTxnId != null) {
      throw StateError(
        'read issued inside runTransaction: the transaction is buffer-only, '
        'so this would return pre-commit state. Read before the transaction, '
        'or after it commits — committed writes are read-your-writes.',
      );
    }
    return _state;
  }

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
  /// after `db.state.mergeNow()`.
  bool get hasPendingWrites => !_state.overlay.isEmpty;

  /// True iff [vid] carries [labelId]. Overlay-aware. Allocation-free
  /// O(log k) where k is per-vid label count.
  bool hasLabel(Vid vid, int labelId) =>
      _r.hasLabelEffective(vid, labelId);

  /// Full label-id set carried by [vid]. Overlay-aware. The returned
  /// iterable is a view — do not mutate.
  Iterable<int> labelsOf(Vid vid) => _r.effectiveLabelsOf(vid);

  // ------------------------------------------------------------- traversal
  // Primitive range API — allocation-free, fastest on AOT.
  //
  // **Snapshot semantics — NOT read-your-writes.** These index directly
  // into the CSR arrays, which reflect only the last merge; overlay-
  // resident edges (committed but not yet folded into the CSR) are
  // invisible here. This is the deliberate exception to the engine's
  // read-your-writes contract — the price of the zero-allocation
  // guarantee. For read-your-writes traversal use [forEachOutNeighbor] /
  // [forEachInNeighbor], or call `db.state.mergeNow()` first.
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
  /// [value]. Boxes each candidate at the boundary; for lookup by a
  /// unique id, prefer the O(1) [nodeByLogicalId].
  Vid? findNodeByProp(int keyId, PropValue value, {int? label}) {
    final s = _r;
    if (label != null) {
      for (final raw in s.effectiveLabelScan(label)) {
        if (s.nodeProps.getBoxed(raw, keyId) == value) return Vid(raw);
      }
      return null;
    }
    final n = s.nextVid;
    for (var v = 0; v < n; v++) {
      if (s.nodeProps.getBoxed(v, keyId) == value) return Vid(v);
    }
    return null;
  }

  /// Every node whose [keyId] property equals [value], ascending by vid.
  /// Pass [label] to restrict to that label. Read-your-writes — see
  /// [findNodeByProp].
  List<Vid> findNodesByProp(int keyId, PropValue value, {int? label}) {
    final s = _r;
    final out = <Vid>[];
    if (label != null) {
      for (final raw in s.effectiveLabelScan(label)) {
        if (s.nodeProps.getBoxed(raw, keyId) == value) out.add(Vid(raw));
      }
    } else {
      final n = s.nextVid;
      for (var v = 0; v < n; v++) {
        if (s.nodeProps.getBoxed(v, keyId) == value) out.add(Vid(v));
      }
    }
    return out;
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
    if (_state.activeTxnId != null) {
      throw StateError(
          'a transaction (txnId=${_state.activeTxnId}) is already in '
          'flight — the engine is single-writer');
    }
    final txnId = _state.allocTxnId();
    _state.activeTxnId = txnId;
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
    }
  }

  Future<void> _commit(Transaction txn, Durability durability) async {
    // Skip empty txn only when there are no pending interns either —
    // otherwise we still need to flush the catalog growth.
    if (txn.bufferedOps.isEmpty && _pendingInterns.isEmpty) return;
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
    // InternString ops were applied at intern-time (the string is
    // already in the local interner). Skip them on apply so we don't
    // trigger the CorruptionDetected mismatch guard.
    for (final seq in ops) {
      if (seq.op is InternString) continue;
      apply(_state, seq, recovery: false);
    }
    _pendingInterns.clear();
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

  /// Active pins on this engine. Tests + tooling use this; v1
  /// doesn't enforce isolation against the pin set, but future
  /// MVCC uses it to gate version retention.
  final Set<LsnPin> _activePins = {};
  int get activePinCount => _activePins.length;

  /// Captures the current LSN as a [LsnPin] — see [LsnPin] /
  /// [IsolationLevel] for v1 semantics. Release the pin via
  /// `pin.release()` when done so future MVCC enforcement doesn't
  /// retain old versions on your behalf.
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
    if (_state.activeTxnId != null) {
      throw StateError(
          'cannot bulkAddEdges while txnId=${_state.activeTxnId} is in '
          'flight');
    }
    if (edges.isEmpty) return const [];
    final txnId = _state.allocTxnId();
    _state.activeTxnId = txnId;
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

      return eids;
    } finally {
      _state.activeTxnId = null;
    }
  }

  // ----- Secondary indexes -------------------------------------

  /// Soft-budget size-event hook. Default unset = silent.
  /// Wire a logger or a test assertion sink here to be notified when
  /// a freshly-built index crosses the [kIndexSizeWarnThreshold]
  /// ratio of [Csr.sizeBytes]. Fired once per `createIndex()`.
  IndexSizeListener? onIndexSizeEvent;

  /// Builds a node-property index from the current state. Fires
  /// [onIndexSizeEvent] if the new index is at or above the soft
  /// budget. The default (non-incremental, non-deferred) index reflects
  /// the loaded fixture and does not update with mutations.
  SecondaryIndex createNodePropertyIndex(IndexSpec spec) =>
      _state.createNodePropertyIndex(spec, onSizeEvent: onIndexSizeEvent);

  /// Builds an edge-property index from the current state. See
  /// [createNodePropertyIndex] for semantics.
  SecondaryIndex createEdgePropertyIndex(IndexSpec spec) =>
      _state.createEdgePropertyIndex(spec, onSizeEvent: onIndexSizeEvent);

  /// Looks up a registered node-property index by name.
  SecondaryIndex? getNodeIndex(String name) => _state.getNodeIndex(name);

  /// Looks up a registered edge-property index by name.
  SecondaryIndex? getEdgeIndex(String name) => _state.getEdgeIndex(name);

  /// Removes a node-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropNodeIndex(String name) => _state.dropNodeIndex(name);

  /// Removes an edge-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropEdgeIndex(String name) => _state.dropEdgeIndex(name);
}
