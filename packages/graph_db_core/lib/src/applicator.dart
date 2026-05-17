import 'exceptions.dart';
import 'mutable_graph_state.dart';
import 'string_interner.dart';
import 'wal_op.dart';

/// The **single** code path that mutates in-memory state (plan §2.1).
///
/// Every write path — live transactions, recovery, snapshot load, bulk
/// import, sync replay — produces a [SequencedWalOp] stream and feeds
/// it to [apply]. There is no other way to advance the
/// [MutableGraphState].
///
/// [recovery] is `true` during WAL replay and bulk import: `AddEdge`
/// then writes the CSR directly instead of routing through the delta
/// overlay (which would otherwise trip a merge mid-replay). Phase 0
/// has no overlay yet, so the flag is plumbed but unused.
///
/// **Phase 0 — skeleton.** The switch is exhaustive (no `default:`
/// clause; the compiler fails on a new [WalOp] subclass), but most
/// arms throw [UnimplementedError]. Phase 2 wires the mutation methods
/// on [MutableGraphState] and replaces each `throw` with the real call.
/// The [BeginTxn] / [CommitTxn] / [InternString] arms are the three
/// already-implementable ops in Phase 0.
void apply(
  MutableGraphState state,
  SequencedWalOp seq, {
  required bool recovery,
}) {
  final op = seq.op;
  switch (op) {
    case BeginTxn():
      // Phase 6 adds transaction-isolation / LSN-pinning machinery; in
      // Phase 0-2's single-writer model the marker is informational.
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
