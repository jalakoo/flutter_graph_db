import 'exceptions.dart';
import 'mutable_graph_state.dart';
import 'string_interner.dart';
import 'wal_op.dart';

/// The **single** code path that mutates in-memory state.
///
/// Every write path — live transactions, recovery, snapshot load, bulk
/// import, sync replay — produces a [SequencedWalOp] stream and feeds
/// it to [apply]. There is no other way to advance the
/// [MutableGraphState].
///
/// [recovery] is `true` during WAL replay (and bulk import). It arms a
/// tripwire: an `AddNode` / `AddEdge` for an entity the loaded snapshot
/// already holds means the replay LSN gate (see `recoverInto`) failed to
/// skip a snapshot-covered op, so `apply` throws [CorruptionDetected]
/// instead of silently double-recording into the overlay. The gate is the
/// primary guarantee; this is a loud backstop.
///
/// The switch is exhaustive (no `default:` clause; the compiler fails
/// on a new [WalOp] subclass) so adding a new [WalOp] subclass is a
/// compile-time prompt to wire up its apply path.
void apply(
  MutableGraphState state,
  SequencedWalOp seq, {
  required bool recovery,
}) {
  final op = seq.op;
  switch (op) {
    case BeginTxn():
      // In the current single-writer model the marker is informational;
      // future transaction-isolation / LSN-pinning machinery can hook
      // here.
      return;
    case CommitTxn():
      return;
    case InternString(:final intId, :final value, :final kind):
      _applyInternString(state, intId, value, kind);
      return;
    case AddNode(
        :final vid,
        :final logicalId,
        :final labelIds,
        :final props,
      ):
      if (recovery && state.vidOfLogicalId(logicalId) != null) {
        throw CorruptionDetected(
            'recovery replayed an AddNode the snapshot already holds '
            '(logicalId "$logicalId", vid ${vid.value}) — the WAL replay '
            'LSN gate failed to skip a snapshot-covered op');
      }
      state.applyAddNode(
        vid,
        logicalId: logicalId,
        labelIds: labelIds,
        props: props,
      );
      return;
    case DelNode(:final vid):
      state.applyDelNode(vid);
      return;
    case SetNodeLabels(:final vid, :final added, :final removed):
      state.applySetNodeLabels(vid, added: added, removed: removed);
      return;
    case SetNodeProp(:final vid, :final keyId, :final value):
      state.applySetNodeProp(vid, keyId, value);
      return;
    case DelNodeProp(:final vid, :final keyId):
      state.applyDelNodeProp(vid, keyId);
      return;
    case AddEdge(
        :final eid,
        :final logicalId,
        :final src,
        :final dst,
        :final typeId,
        :final props,
      ):
      if (recovery && eid.value < state.csr.edgeCount) {
        throw CorruptionDetected(
            'recovery replayed an AddEdge the snapshot already holds '
            '(eid ${eid.value}) — the WAL replay LSN gate failed to skip a '
            'snapshot-covered op');
      }
      state.applyAddEdge(
        eid,
        logicalId: logicalId,
        src: src,
        dst: dst,
        typeId: typeId,
        props: props,
      );
      return;
    case DelEdge(:final eid):
      state.applyDelEdge(eid);
      return;
    case SetEdgeProp(:final eid, :final keyId, :final value):
      state.applySetEdgeProp(eid, keyId, value);
      return;
    case DelEdgeProp(:final eid, :final keyId):
      state.applyDelEdgeProp(eid, keyId);
      return;
    case DeclareConstraint(
        :final name,
        :final labelId,
        :final keyId,
        :final kind,
      ):
      state.applyDeclareConstraint(
        name: name,
        labelId: labelId,
        keyId: keyId,
        kind: kind,
      );
      return;
    case DropConstraint(:final name):
      state.applyDropConstraint(name);
      return;
  }
}

void _applyInternString(
  MutableGraphState state,
  int intId,
  String value,
  StringKind kind,
) {
  // The interner is the one mutator already on MutableGraphState. WAL
  // replay assumes a single writer authored the WAL, so re-interning by
  // name on the local interner should produce the same id. A mismatch
  // means the WAL is from a different writer (or the local state is
  // not empty at replay start) — fatal.
  final assigned = switch (kind) {
    StringKind.label => state.strings.internLabel(value),
    StringKind.edgeType => state.strings.internEdgeType(value),
    StringKind.propKey => state.strings.internPropKey(value),
  };
  if (assigned != intId) {
    throw CorruptionDetected(
        'InternString id mismatch for "$value" (kind: $kind): '
        'WAL recorded $intId, local interner returned $assigned');
  }
}
