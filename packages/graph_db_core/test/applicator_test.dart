import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

MutableGraphState _empty() => MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const [],
      edgeTypeNames: const [],
      vidSpace: 16,
      eidSpace: 16,
    );

void main() {
  test('BeginTxn / CommitTxn are no-ops in Phase 0', () {
    final s = _empty();
    expect(
      () => apply(
        s,
        const SequencedWalOp(lsn: 0, txnId: 1, op: BeginTxn()),
        recovery: false,
      ),
      returnsNormally,
    );
    expect(
      () => apply(
        s,
        const SequencedWalOp(lsn: 1, txnId: 1, op: CommitTxn(1)),
        recovery: false,
      ),
      returnsNormally,
    );
  });

  test('InternString interns the recorded id into the StringInterner', () {
    final s = _empty();
    expect(s.strings.labelCount, 0);
    apply(
      s,
      const SequencedWalOp(
        lsn: 0,
        txnId: 1,
        op: InternString(intId: 0, value: 'Person', kind: StringKind.label),
      ),
      recovery: true,
    );
    expect(s.strings.labelOf(0), 'Person');
    expect(s.strings.labelCount, 1);
  });

  test(
      'InternString with a mismatched id raises CorruptionDetected '
      '(local interner already had a different mapping)', () {
    final s = _empty();
    // Pre-intern → id 0.
    s.strings.internLabel('Person');
    // WAL claims id 5 → mismatch.
    expect(
      () => apply(
        s,
        const SequencedWalOp(
          lsn: 0,
          txnId: 1,
          op:
              InternString(intId: 5, value: 'Person', kind: StringKind.label),
        ),
        recovery: true,
      ),
      throwsA(isA<CorruptionDetected>()),
    );
  });

  test('AddNode routes to MutableGraphState.applyAddNode (Phase 2A)', () {
    final s = _empty();
    final lbl = s.strings.internLabel('Person');
    apply(
      s,
      SequencedWalOp(
        lsn: 0,
        txnId: 1,
        op: AddNode(
          vid: const Vid(0),
          logicalId: 'uuid-0',
          labelIds: [lbl],
          props: const {},
        ),
      ),
      recovery: true,
    );
    expect(s.isNodeVisible(const Vid(0)), isTrue);
    expect(s.effectiveLabelOf(const Vid(0)), lbl);
  });

  test('constraint ops throw UnimplementedError (Phase 6)', () {
    final s = _empty();
    expect(
      () => apply(
        s,
        const SequencedWalOp(
          lsn: 0,
          txnId: 1,
          op: DeclareConstraint(name: 'foo'),
        ),
        recovery: true,
      ),
      throwsA(isA<UnimplementedError>()),
    );
  });
}
