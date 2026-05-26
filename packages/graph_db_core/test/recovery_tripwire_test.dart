import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
// White-box: apply() is the internal single-mutation funnel, not part of the
// public surface — import it directly to exercise the recovery tripwire.
import 'package:graph_db_core/src/applicator.dart';
import 'package:test/test.dart';

MutableGraphState _state() => MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const ['N'],
      edgeTypeNames: const [],
      vidSpace: 16,
      eidSpace: 16,
    );

void main() {
  test('recovery re-applying an AddNode the state already holds throws '
      'CorruptionDetected (LSN-gate tripwire)', () {
    final state = _state();
    final op = const AddNode(
      vid: Vid(0),
      logicalId: 'fixed-id',
      labelIds: [0], // 'N'
      props: {},
    );
    // Live apply establishes the node.
    apply(state, SequencedWalOp(lsn: 0, txnId: 1, op: op), recovery: false);
    expect(state.vidOfLogicalId('fixed-id'), 0);

    // Re-applying during recovery means the LSN gate failed to skip a
    // snapshot-covered op — must fail loud, not silently double-record.
    expect(
      () => apply(state, SequencedWalOp(lsn: 0, txnId: 1, op: op),
          recovery: true),
      throwsA(isA<CorruptionDetected>()),
    );
  });
}
