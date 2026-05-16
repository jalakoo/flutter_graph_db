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
    case AddNode():
      throw UnimplementedError(
          'AddNode applies in Phase 2 — MutableGraphState mutation '
          'methods are not yet defined.');
    case DelNode():
      throw UnimplementedError('DelNode applies in Phase 2.');
    case SetNodeLabels():
      throw UnimplementedError('SetNodeLabels applies in Phase 2.');
    case SetNodeProp():
      throw UnimplementedError('SetNodeProp applies in Phase 2.');
    case DelNodeProp():
      throw UnimplementedError('DelNodeProp applies in Phase 2.');
    case AddEdge():
      throw UnimplementedError('AddEdge applies in Phase 2.');
    case DelEdge():
      throw UnimplementedError('DelEdge applies in Phase 2.');
    case SetEdgeProp():
      throw UnimplementedError('SetEdgeProp applies in Phase 2.');
    case DelEdgeProp():
      throw UnimplementedError('DelEdgeProp applies in Phase 2.');
    case DeclareConstraint():
      throw UnimplementedError(
          'DeclareConstraint applies in Phase 6 (constraint catalog).');
    case DropConstraint():
      throw UnimplementedError(
          'DropConstraint applies in Phase 6 (constraint catalog).');
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
