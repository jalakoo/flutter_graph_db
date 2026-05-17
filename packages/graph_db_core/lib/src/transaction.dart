/// Transaction (plan §2.1, §6.4 / §14 Phase 2B).
///
/// Phase 2B is a **buffer-only** transaction: every mutation method
/// records an unsequenced [WalOp] in an internal buffer + immediately
/// reserves any allocated `vid` / `eid`. On commit, the runtime
/// assigns LSNs, wraps every op in a [SequencedWalOp], and feeds the
/// stream (`BeginTxn` → buffered ops → `CommitTxn`) through the
/// applicator. On rollback the buffer is dropped — any vids / eids
/// allocated inside the body are **not** reused (plan §3.6: ids never
/// reused, intentional cost of monotonic identity).
///
/// **No read-your-writes.** Reads inside the body (`db.outDegree`,
/// `db.getNodeProp`, etc.) see the **pre-commit** state. Sequence
/// dependent reads across multiple txns. Phase 6 (ACID hardening) may
/// add snapshot isolation with proper read-your-writes.
///
/// **No nesting, no concurrency.** Plan §2.3 single-writer model.
/// `runTransaction` while a txn is in flight throws.
library;

import 'constraints/constraint.dart';
import 'identity/uuid_v7.dart';
import 'ids.dart';
import 'mutable_graph_state.dart';
import 'prop_value.dart';
import 'wal_op.dart';

/// A live transaction handle. Use the mutation methods; the returned
/// `Vid` / `Eid` is immediately stable (allocated against the state)
/// even if the txn later rolls back.
class Transaction {
  final int txnId;
  final MutableGraphState _state;
  final List<WalOp> _buffer = [];

  /// When `true`, `setNodeProp` / `setEdgeProp` auto-capture the
  /// current value into `prevValue` (plan §6.4 / §14 Phase 2F). Off
  /// by default — the capture costs a `getBoxed` per call. Wire on
  /// for richer audit trails or simpler sync conflict detection.
  final bool capturePrevValues;

  bool _terminated = false;

  Transaction(this.txnId, this._state, {this.capturePrevValues = false});

  /// The unsequenced ops queued so far. Exposed for tests + tooling;
  /// callers should not mutate.
  List<WalOp> get bufferedOps => List.unmodifiable(_buffer);

  /// True once the txn has committed or rolled back. Further mutation
  /// throws [StateError].
  bool get isTerminated => _terminated;

  void _check() {
    if (_terminated) {
      throw StateError(
          'transaction $txnId already terminated — start a new txn');
    }
  }

  // ----- node mutations -----

  /// Allocates a fresh vid, buffers an `AddNode` op, returns the vid.
  /// [logicalId] defaults to a fresh UUIDv7 (plan §6.3 — time-ordered
  /// stable identity).
  Vid addNode({
    required List<int> labelIds,
    Map<int, PropValue> props = const {},
    String? logicalId,
  }) {
    _check();
    final vid = _state.allocVid();
    _buffer.add(AddNode(
      vid: vid,
      logicalId: logicalId ?? newUuidV7(),
      labelIds: List.unmodifiable(labelIds),
      props: Map.unmodifiable(props),
    ));
    return vid;
  }

  void delNode(Vid vid) {
    _check();
    _buffer.add(DelNode(vid));
  }

  void setNodeLabels(
    Vid vid, {
    required List<int> added,
    required List<int> removed,
  }) {
    _check();
    _buffer.add(SetNodeLabels(
      vid: vid,
      added: List.unmodifiable(added),
      removed: List.unmodifiable(removed),
    ));
  }

  /// [prevValue] is opt-in (plan §6.4) — pass-through unless the
  /// owning txn was constructed with [capturePrevValues] = true, in
  /// which case the current value is captured automatically.
  void setNodeProp(
    Vid vid,
    int keyId,
    PropValue value, {
    PropValue? prevValue,
  }) {
    _check();
    final pv = prevValue ??
        (capturePrevValues
            ? _state.nodeProps.getBoxed(vid.value, keyId)
            : null);
    _buffer.add(SetNodeProp(
      vid: vid,
      keyId: keyId,
      value: value,
      prevValue: pv,
    ));
  }

  void delNodeProp(Vid vid, int keyId) {
    _check();
    _buffer.add(DelNodeProp(vid: vid, keyId: keyId));
  }

  // ----- edge mutations -----

  /// Allocates a fresh eid, buffers an `AddEdge` op, returns the eid.
  Eid addEdge({
    required Vid src,
    required Vid dst,
    required int typeId,
    Map<int, PropValue> props = const {},
    String? logicalId,
  }) {
    _check();
    final eid = _state.allocEid();
    _buffer.add(AddEdge(
      eid: eid,
      logicalId: logicalId ?? newUuidV7(),
      src: src,
      dst: dst,
      typeId: typeId,
      props: Map.unmodifiable(props),
    ));
    return eid;
  }

  void delEdge(Eid eid) {
    _check();
    _buffer.add(DelEdge(eid));
  }

  void setEdgeProp(
    Eid eid,
    int keyId,
    PropValue value, {
    PropValue? prevValue,
  }) {
    _check();
    final pv = prevValue ??
        (capturePrevValues
            ? _state.edgeProps.getBoxed(eid.value, keyId)
            : null);
    _buffer.add(SetEdgeProp(
      eid: eid,
      keyId: keyId,
      value: value,
      prevValue: pv,
    ));
  }

  void delEdgeProp(Eid eid, int keyId) {
    _check();
    _buffer.add(DelEdgeProp(eid: eid, keyId: keyId));
  }

  // ----- constraint catalog (plan §14 Phase 6C) -----

  /// Records a `DeclareConstraint` WAL op (plan §4 / §14 Phase 6C).
  /// The catalog enforcement (validation against existing data,
  /// auto-create of the underlying unique index) runs at apply-time;
  /// if validation fails, the whole txn rolls back.
  void declareConstraint(ConstraintSpec spec) {
    _check();
    final kind = switch (spec) {
      UniqueConstraint() => ConstraintKind.unique,
      ExistenceConstraint() => ConstraintKind.existence,
    };
    _buffer.add(DeclareConstraint(
      name: spec.name,
      labelId: spec.labelId,
      keyId: spec.keyId,
      kind: kind,
    ));
  }

  /// Drops the constraint named [name] (idempotent — see plan §6.4).
  void dropConstraint(String name) {
    _check();
    _buffer.add(DropConstraint(name: name));
  }

  void _markTerminated() {
    _terminated = true;
  }
}

/// The sequenced stream a committed txn produces — exposed for tests
/// and for Phase 2C's WAL writer plumbing.
class SequencedTxn {
  final int txnId;
  final List<SequencedWalOp> ops;
  final int commitLsn;
  const SequencedTxn({
    required this.txnId,
    required this.ops,
    required this.commitLsn,
  });
}

/// Internal — marks [txn] terminated so further mutations throw.
/// Lives in this library so it can reach the private `_markTerminated`.
/// **Do not call from user code.**
void markTransactionTerminated(Transaction txn) => txn._markTerminated();
