import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

void main() {
  test('BeginTxn / CommitTxn are constructible (const)', () {
    expect(const BeginTxn(), isA<WalOp>());
    expect(const CommitTxn(42).commitLsn, 42);
  });

  test('AddNode carries all the §6.4 fields', () {
    const op = AddNode(
      vid: Vid(7),
      logicalId: 'uuid-7',
      labelIds: [0, 1],
      props: {3: PropString('name')},
    );
    expect(op.vid.value, 7);
    expect(op.labelIds, [0, 1]);
    expect(op.props[3], const PropString('name'));
  });

  test('AddEdge wires src/dst/typeId', () {
    const op = AddEdge(
      eid: Eid(9),
      logicalId: 'uuid-9',
      src: Vid(1),
      dst: Vid(2),
      typeId: 0,
      props: {},
    );
    expect(op.src.value, 1);
    expect(op.dst.value, 2);
    expect(op.typeId, 0);
  });

  test('SetNodeProp prevValue defaults to null and is opt-in', () {
    const a = SetNodeProp(vid: Vid(0), keyId: 1, value: PropInt(7));
    expect(a.prevValue, null);
    const b = SetNodeProp(
      vid: Vid(0),
      keyId: 1,
      value: PropInt(7),
      prevValue: PropInt(6),
    );
    expect(b.prevValue, const PropInt(6));
  });

  test('InternString carries id + value + kind', () {
    const op = InternString(intId: 0, value: 'Person', kind: StringKind.label);
    expect(op.intId, 0);
    expect(op.value, 'Person');
    expect(op.kind, StringKind.label);
  });

  test('SequencedWalOp wraps lsn/txnId around a payload', () {
    const seq = SequencedWalOp(lsn: 10, txnId: 1, op: BeginTxn());
    expect(seq.lsn, 10);
    expect(seq.txnId, 1);
    expect(seq.op, isA<BeginTxn>());
  });

  test('sealed switch is exhaustive without a default', () {
    String describe(WalOp op) => switch (op) {
          BeginTxn() => 'beginTxn',
          CommitTxn() => 'commitTxn',
          AddNode() => 'addNode',
          DelNode() => 'delNode',
          SetNodeLabels() => 'setNodeLabels',
          SetNodeProp() => 'setNodeProp',
          DelNodeProp() => 'delNodeProp',
          AddEdge() => 'addEdge',
          DelEdge() => 'delEdge',
          SetEdgeProp() => 'setEdgeProp',
          DelEdgeProp() => 'delEdgeProp',
          DeclareConstraint() => 'declareConstraint',
          DropConstraint() => 'dropConstraint',
          InternString() => 'internString',
        };
    expect(describe(const BeginTxn()), 'beginTxn');
    expect(describe(const DelNode(Vid(1))), 'delNode');
    expect(
      describe(const InternString(
        intId: 0,
        value: 'x',
        kind: StringKind.propKey,
      )),
      'internString',
    );
  });
}
