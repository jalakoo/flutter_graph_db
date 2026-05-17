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

/// Public facade over the engine (plan §7.1).
///
/// Phase-1 entry points only — there are no mutations and no
/// persistence here yet. Future phases add `GraphDb.open(path: ...)` for
/// WAL-backed durability, `runInTransaction` for writes, and
/// `executeQuery` for GQL. The read API surfaced here is the locked
/// design from plan §5: the **primitive range** layer is the core, with
/// a callback-based "for each" sugar layer on top.
class GraphDb {
  final MutableGraphState _state;

  /// Optional WAL sink (plan §2.2). When non-null, every committed
  /// transaction's sequenced ops are appended through this sink with
  /// [Durability.fsync] before the applicator mutates state. When
  /// null, the engine runs purely in-memory (tests + the read-only
  /// fixture flow).
  final WalSink? _sink;

  /// `InternString` ops queued between transactions, flushed at the
  /// front of the next commit so recovery sees the catalog growth in
  /// the order it was applied (plan §3.5, §6.4).
  final List<InternString> _pendingInterns = [];

  GraphDb._(this._state, [this._sink]);

  /// Wraps an already-built [MutableGraphState] — the Phase-1 entry
  /// point. Fixture loaders (e.g. `SocialGraph.build()` from
  /// `package:graph_db_core/samples.dart`) hand back a [GraphDb] this way.
  ///
  /// Pass [sink] to enable WAL writes on commit (Phase 2C). The sink
  /// is closed by [close]. `graph_db_wal`'s `WalWriter` is the
  /// production-grade implementation.
  factory GraphDb.fromState(MutableGraphState state, {WalSink? sink}) =>
      GraphDb._(state, sink);

  /// Closes the engine: flushes any pending `InternString` ops as a
  /// final empty-but-not-quite commit (if a sink is configured), then
  /// closes the sink. Safe to call once; subsequent commit attempts
  /// fail at the sink layer.
  Future<void> close() async {
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

  /// Underlying state — for advanced callers and tests. The public API
  /// here covers the documented Phase-1 surface; Phase 2 will lock this
  /// behind the transaction model.
  MutableGraphState get state => _state;

  /// CSR — exposed so callers writing extremely tight loops can index
  /// the typed arrays directly (plan §5 primitive layer).
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

  // -------------------------------------------------------------- topology

  int get nodeCount => _state.csr.nodeCount;
  int get edgeCount => _state.csr.edgeCount;
  int outDegree(Vid vid) => _state.csr.outDegree(vid.value);
  int inDegree(Vid vid) => _state.csr.inDegree(vid.value);
  int labelOf(Vid vid) => _state.csr.labelOf[vid.value];

  // ------------------------------------------------------------- traversal
  // Primitive range API — allocation-free, fastest on AOT (Spike A).

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
  /// Hoist [visit] to a top-level function or a field-bound closure to
  /// keep this path allocation-free (Spike A: callback shape is
  /// gc/op 0.000 when the closure is prebuilt).
  void forEachOutNeighbor(
    Vid vid,
    void Function(Vid dst, Eid eid, int edgeType) visit,
  ) {
    final csr = _state.csr;
    final end = csr.rowPtrOut[vid.value + 1];
    for (var i = csr.rowPtrOut[vid.value]; i < end; i++) {
      visit(
        Vid(csr.colIdxOut[i]),
        Eid(csr.edgeIdOut[i]),
        csr.edgeTypeOut[i],
      );
    }
  }

  /// Callback sugar — invokes [visit] for each in-edge of [vid].
  void forEachInNeighbor(
    Vid vid,
    void Function(Vid src, Eid eid, int edgeType) visit,
  ) {
    final csr = _state.csr;
    final end = csr.rowPtrIn[vid.value + 1];
    for (var i = csr.rowPtrIn[vid.value]; i < end; i++) {
      visit(
        Vid(csr.colIdxIn[i]),
        Eid(csr.edgeIdIn[i]),
        csr.edgeTypeIn[i],
      );
    }
  }

  // ---------------------------------------------------------------- labels

  /// All vids carrying [labelId], in ascending order. The returned
  /// [Uint32List] is a view into a pre-built sorted index — do not
  /// mutate it.
  Uint32List labelScan(int labelId) => _state.labelScan(labelId);

  // --------------------------------------------------------- property reads
  //
  // Raw primitives — caller knows the type (`columnType` on the
  // property store) or guards via [hasNodeProp] / [nodePropIsNull].
  // Use [getNodeProp] / [getEdgeProp] for the boxed boundary form.

  bool hasNodeProp(Vid vid, int keyId) => _state.hasNodeProp(vid, keyId);
  bool nodePropIsNull(Vid vid, int keyId) =>
      _state.nodeProps.isNull(vid.value, keyId);
  ColumnType? nodePropType(int keyId) =>
      _state.nodeProps.columnType(keyId);

  int getNodeIntProp(Vid vid, int keyId) =>
      _state.getNodeIntProp(vid, keyId);
  double getNodeDoubleProp(Vid vid, int keyId) =>
      _state.getNodeDoubleProp(vid, keyId);
  bool getNodeBoolProp(Vid vid, int keyId) =>
      _state.getNodeBoolProp(vid, keyId);
  String getNodeStringProp(Vid vid, int keyId) =>
      _state.getNodeStringProp(vid, keyId);

  bool hasEdgeProp(Eid eid, int keyId) => _state.hasEdgeProp(eid, keyId);
  ColumnType? edgePropType(int keyId) =>
      _state.edgeProps.columnType(keyId);

  int getEdgeIntProp(Eid eid, int keyId) =>
      _state.getEdgeIntProp(eid, keyId);
  String getEdgeStringProp(Eid eid, int keyId) =>
      _state.getEdgeStringProp(eid, keyId);

  /// Boundary read — constructs and returns a [PropValue]. Allocates;
  /// use the typed primitive accessors above on the hot path.
  PropValue? getNodeProp(Vid vid, int keyId) =>
      _state.nodeProps.getBoxed(vid.value, keyId);
  PropValue? getEdgeProp(Eid eid, int keyId) =>
      _state.edgeProps.getBoxed(eid.value, keyId);

  // ----- Transactions (plan §2.1, §6.4 / §14 Phase 2B) --------------------

  /// Runs [body] inside a transaction.
  ///
  /// On normal return, commits: the buffered ops are sealed into a
  /// `BeginTxn` → ops → `CommitTxn` stream (LSNs assigned in order),
  /// then routed through the applicator. The return value is forwarded
  /// to the caller.
  ///
  /// On any throw, rolls back: the buffer is dropped and the state
  /// is untouched. **Allocated vids / eids are still consumed** —
  /// plan §3.6 (ids never reused). The exception propagates.
  ///
  /// Single-writer model (plan §2.3): nested + concurrent
  /// `runTransaction` calls throw [StateError].
  ///
  /// Empty transactions (body queued no ops) are skipped — no `BeginTxn`
  /// / `CommitTxn` are emitted, no LSNs consumed.
  /// [durability] — per-call override of the engine default
  /// (plan §6.7). Defaults to [Durability.group]: this commit lands
  /// in the next group-fsync window (1 ms by default). Pass
  /// [Durability.fsync] for a per-commit fsync. Tests that want to
  /// avoid the group-window wait can pass [Durability.fsync] or
  /// [Durability.none].
  ///
  /// [capturePrevValues] — when `true`, `setNodeProp` / `setEdgeProp`
  /// inside the txn auto-capture the current value into the WAL op's
  /// `prevValue` field (plan §6.4 / §14 Phase 2F). Off by default —
  /// each capture costs a `getBoxed` allocation. Enable for audit
  /// trails or simpler sync conflict detection.
  Future<T> runTransaction<T>(
    FutureOr<T> Function(Transaction txn) body, {
    Durability durability = Durability.group,
    bool capturePrevValues = false,
  }) async {
    if (_state.activeTxnId != null) {
      throw StateError(
          'a transaction (txnId=${_state.activeTxnId}) is already in '
          'flight — Phase 2B is single-writer (plan §2.3)');
    }
    final txnId = _state.allocTxnId();
    _state.activeTxnId = txnId;
    final txn = Transaction(
      txnId,
      _state,
      capturePrevValues: capturePrevValues,
    );
    try {
      final result = await body(txn);
      await _commit(txn, durability);
      return result;
    } catch (_) {
      // Rollback: drop the buffer. Allocated vids/eids are NOT
      // released — plan §3.6 monotonic identity.
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
    // per the requested mode (plan §6.7).
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
    // After applying, check the overlay merge threshold (plan §14
    // Phase 2E). Uses the worker isolate when a coordinator is wired
    // (plan §14 Phase 2 polish — Spike B port), otherwise falls back
    // to the synchronous main-isolate fold.
    await _state.maybeMergeOverlayAsync();
  }

  void _terminate(Transaction txn) {
    if (!txn.isTerminated) {
      markTransactionTerminated(txn);
    }
  }

  // ----- Phase 6A: observable LSN ------------------------------------------

  /// LSN of the most recently applied op. Foundation for snapshot
  /// isolation (plan §14 Phase 6A) — readers can capture this and
  /// later compare to know whether the engine has advanced. Full
  /// pinning + MVCC enforcement is Phase 6B.
  int get currentLsn => _state.nextLsn - 1;

  /// Current next-LSN — the LSN the next committed op will receive.
  int get nextLsn => _state.nextLsn;

  /// Active pins on this engine. Tests + tooling use this; v1
  /// doesn't enforce isolation against the pin set, but future
  /// MVCC (Phase 6B+) uses it to gate version retention.
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

  // ----- Phase 6C: constraint catalog --------------------------------------

  /// Read-only handle to the engine's constraint catalog. Application
  /// code reads this to introspect active constraints; declare /
  /// drop go through `runTransaction` so the WAL records them and
  /// recovery rebuilds the catalog.
  ConstraintCatalog get constraints => _state.constraints;

  // ----- Bulk write path (plan §14 Phase 2F) -------------------------------

  /// Bulk edge import — bypasses the overlay and rebuilds the CSR
  /// directly with the new edges folded in. Single WAL transaction
  /// covers the whole batch. Returns the allocated eids in input
  /// order.
  ///
  /// Use over a `runTransaction` loop when importing > a few thousand
  /// edges: the overlay path would trip the merge threshold mid-batch
  /// and pay multiple full-CSR rebuilds; this path pays exactly one.
  /// Plan §14: "100k bulk-import in < 1s".
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
          'flight (plan §2.3 single-writer)');
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

  // ----- Secondary indexes (plan §3.3) -------------------------------------

  /// Soft-budget size-event hook (plan §3.3). Default unset = silent.
  /// Wire a logger or a test assertion sink here to be notified when
  /// a freshly-built index crosses the [kIndexSizeWarnThreshold]
  /// ratio of [Csr.sizeBytes]. Fired once per `createIndex()`.
  IndexSizeListener? onIndexSizeEvent;

  /// Builds a node-property index from the current state. Fires
  /// [onIndexSizeEvent] if the new index is at or above the soft
  /// budget. Phase 1 is read-only — the index reflects the loaded
  /// fixture and does not update with mutations (Phase 5 wires
  /// incremental update).
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
