/// Transaction.
///
/// This is a **buffer-only** transaction: every mutation method
/// records an unsequenced [WalOp] in an internal buffer + immediately
/// reserves any allocated `vid` / `eid`. On commit, the runtime
/// assigns LSNs, wraps every op in a [SequencedWalOp], and feeds the
/// stream (`BeginTxn` → buffered ops → `CommitTxn`) through the
/// applicator. On rollback the buffer is dropped — any vids / eids
/// allocated inside the body are **not** reused.
///
/// **Reads inside the body: snapshot-at-start only.** A high-level read
/// (`db.nodeCount`, `db.getNodeProp`, `db.labelScan`, traversal, the
/// finders, …) issued *before the first mutation* returns the
/// committed-as-of-begin snapshot. Once the txn has buffered a write, a
/// further read throws a [StateError] — a buffer-only txn cannot offer
/// read-your-writes, so a post-write read would silently expose pre-write
/// state. Read before mutating, or split the transaction. (No MVCC; the
/// engine stays single-writer.)
///
/// **No nesting, no concurrency.** single-writer model.
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
  /// current value into `prevValue`. Off by default — the capture
  /// costs a `getBoxed` per call. Wire on for richer audit trails or
  /// simpler sync conflict detection.
  final bool capturePrevValues;

  bool _terminated = false;

  // Journaled interners, wired by `GraphDb.runTransaction`. The
  // string-keyed convenience methods route through these so a new
  // label / edge type / prop key is recorded in the WAL (via the
  // engine's pending-intern queue) before any op references it. Null
  // when a `Transaction` is built directly (e.g. in low-level tests),
  // in which case the string-keyed methods throw.
  final int Function(String name)? _internLabel;
  final int Function(String name)? _internEdgeType;
  final int Function(String name)? _internPropKey;

  Transaction(
    this.txnId,
    this._state, {
    this.capturePrevValues = false,
    int Function(String name)? internLabel,
    int Function(String name)? internEdgeType,
    int Function(String name)? internPropKey,
  })  : _internLabel = internLabel,
        _internEdgeType = internEdgeType,
        _internPropKey = internPropKey;

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

  /// Buffers an op and flags the active transaction as having written.
  /// Once a txn has written, a subsequent high-level read throws:
  /// snapshot-at-start only guarantees committed-as-of-begin state, never
  /// read-your-writes, so a read after a write would silently observe
  /// pre-write state.
  void _record(WalOp op) {
    _buffer.add(op);
    _state.activeTxnHasWrites = true;
  }

  // ----- node mutations -----

  /// Allocates a fresh vid, buffers an `AddNode` op, returns the vid.
  /// [logicalId] defaults to a fresh UUIDv7.
  Vid addNode({
    required List<int> labelIds,
    Map<int, PropValue> props = const {},
    String? logicalId,
  }) {
    _check();
    final vid = _state.allocVid();
    _record(AddNode(
      vid: vid,
      logicalId: logicalId ?? newUuidV7(),
      labelIds: List.unmodifiable(labelIds),
      props: Map.unmodifiable(props),
    ));
    return vid;
  }

  void delNode(Vid vid) {
    _check();
    _record(DelNode(vid));
  }

  void setNodeLabels(
    Vid vid, {
    required List<int> added,
    required List<int> removed,
  }) {
    _check();
    _record(SetNodeLabels(
      vid: vid,
      added: List.unmodifiable(added),
      removed: List.unmodifiable(removed),
    ));
  }

  /// [prevValue] is opt-in — pass-through unless the
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
    _record(SetNodeProp(
      vid: vid,
      keyId: keyId,
      value: value,
      prevValue: pv,
    ));
  }

  void delNodeProp(Vid vid, int keyId) {
    _check();
    _record(DelNodeProp(vid: vid, keyId: keyId));
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
    _record(AddEdge(
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
    _record(DelEdge(eid));
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
    _record(SetEdgeProp(
      eid: eid,
      keyId: keyId,
      value: value,
      prevValue: pv,
    ));
  }

  void delEdgeProp(Eid eid, int keyId) {
    _check();
    _record(DelEdgeProp(eid: eid, keyId: keyId));
  }

  // ----- string-keyed convenience overloads -----
  //
  // Ergonomic wrappers that auto-intern names so callers don't have to
  // `internLabel` / `internPropKey` up front. Each name is interned
  // through the engine's journaled path (recorded in the WAL). The
  // int-keyed methods above stay the documented hot path — interning is
  // a map lookup per name and these allocate the translated maps.

  int _intern(int Function(String)? fn, String kind, String name) {
    if (fn == null) {
      throw StateError(
        'string-keyed transaction methods require a transaction created by '
        'GraphDb.runTransaction (no $kind interner is wired)',
      );
    }
    return fn(name);
  }

  /// String-keyed [addNode]: [labels] and [props] keys are auto-interned.
  Vid addNodeNamed({
    required List<String> labels,
    Map<String, PropValue> props = const {},
    String? logicalId,
  }) {
    final labelIds = [
      for (final l in labels) _intern(_internLabel, 'label', l),
    ];
    final propIds = <int, PropValue>{
      for (final e in props.entries)
        _intern(_internPropKey, 'property key', e.key): e.value,
    };
    return addNode(labelIds: labelIds, props: propIds, logicalId: logicalId);
  }

  /// String-keyed [addEdge]: [type] and [props] keys are auto-interned.
  Eid addEdgeNamed({
    required Vid src,
    required Vid dst,
    required String type,
    Map<String, PropValue> props = const {},
    String? logicalId,
  }) {
    final propIds = <int, PropValue>{
      for (final e in props.entries)
        _intern(_internPropKey, 'property key', e.key): e.value,
    };
    return addEdge(
      src: src,
      dst: dst,
      typeId: _intern(_internEdgeType, 'edge type', type),
      props: propIds,
      logicalId: logicalId,
    );
  }

  /// String-keyed [setNodeProp]: [key] is auto-interned.
  void setNodePropNamed(
    Vid vid,
    String key,
    PropValue value, {
    PropValue? prevValue,
  }) =>
      setNodeProp(vid, _intern(_internPropKey, 'property key', key), value,
          prevValue: prevValue);

  /// String-keyed [setEdgeProp]: [key] is auto-interned.
  void setEdgePropNamed(
    Eid eid,
    String key,
    PropValue value, {
    PropValue? prevValue,
  }) =>
      setEdgeProp(eid, _intern(_internPropKey, 'property key', key), value,
          prevValue: prevValue);

  // ----- constraint catalog -----

  /// Records a `DeclareConstraint` WAL op.
  /// The catalog enforcement (validation against existing data,
  /// auto-create of the underlying unique index) runs at apply-time;
  /// if validation fails, the whole txn rolls back.
  void declareConstraint(ConstraintSpec spec) {
    _check();
    final kind = switch (spec) {
      UniqueConstraint() => ConstraintKind.unique,
      ExistenceConstraint() => ConstraintKind.existence,
    };
    _record(DeclareConstraint(
      name: spec.name,
      labelId: spec.labelId,
      keyId: spec.keyId,
      kind: kind,
    ));
  }

  /// Drops the constraint named [name] (idempotent — see).
  void dropConstraint(String name) {
    _check();
    _record(DropConstraint(name: name));
  }

  void _markTerminated() {
    _terminated = true;
  }
}

/// The sequenced stream a committed txn produces — exposed for tests
/// and for the WAL writer plumbing.
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
