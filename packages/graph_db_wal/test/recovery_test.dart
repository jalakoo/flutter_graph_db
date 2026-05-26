import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

GraphDb _emptyDbBacked(WalStore store) {
  // Build empty in-memory state, wire a WalWriter sink.
  final state = MutableGraphState.fromFixture(
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
  return GraphDb.fromState(state, sink: WalWriter(store));
}

void main() {
  group('WAL round-trip', () {
    test('commit then recover reproduces the same graph', () async {
      final store = InMemoryWalStore();
      final db = _emptyDbBacked(store);
      final personLabel = db.internLabel('Person');
      final knowsType = db.internEdgeType('knows');
      final nameKey = db.internPropKey('name');
      final ageKey = db.internPropKey('age');

      late Vid alice;
      late Vid bob;
      await db.runTransaction((txn) {
        alice = txn.addNode(labelIds: [personLabel], props: {
          nameKey: const PropString('Alice'),
          ageKey: const PropInt(30),
        });
        bob = txn.addNode(labelIds: [personLabel], props: {
          nameKey: const PropString('Bob'),
          ageKey: const PropInt(25),
        });
        txn.addEdge(src: alice, dst: bob, typeId: knowsType);
      });

      // Recover into a fresh state from the same store.
      final recovered = await recoverGraphState(store: store);

      // Catalog re-interned to the same ids.
      expect(recovered.strings.labelIdOf('Person'), personLabel);
      expect(recovered.strings.edgeTypeIdOf('knows'), knowsType);
      expect(recovered.strings.propKeyIdOf('name'), nameKey);
      expect(recovered.strings.propKeyIdOf('age'), ageKey);

      // Nodes + props recovered.
      expect(recovered.isNodeVisible(alice), isTrue);
      expect(recovered.isNodeVisible(bob), isTrue);
      expect(recovered.nodeProps.getString(alice.value, nameKey), 'Alice');
      expect(recovered.nodeProps.getInt(alice.value, ageKey), 30);
      expect(recovered.nodeProps.getString(bob.value, nameKey), 'Bob');

      // Edge survived (in overlay since the empty-state CSR had no edges).
      final outOfAlice = <int>[];
      recovered.forEachOutEdge(alice, (e, dst, _) => outOfAlice.add(dst.value));
      expect(outOfAlice, [bob.value]);
    });

    test('uncommitted txns are dropped on recovery (plan §6.5)', () async {
      final store = InMemoryWalStore();
      final codec = const WalCodec();
      // Manually write Begin + AddNode for txnId=1 WITHOUT a CommitTxn.
      // recovery should drop the AddNode.
      Future<void> writeRaw(SequencedWalOp op) async {
        await store.append(
          codec.encodeFramed(op),
          durability: Durability.fsync,
        );
      }

      final personLabel = 0;
      await writeRaw(SequencedWalOp(
        lsn: 0,
        txnId: 1,
        op: const InternString(
          intId: 0,
          value: 'Person',
          kind: StringKind.label,
        ),
      ));
      await writeRaw(const SequencedWalOp(lsn: 1, txnId: 2, op: BeginTxn()));
      await writeRaw(SequencedWalOp(
        lsn: 2,
        txnId: 2,
        op: AddNode(
          vid: const Vid(0),
          logicalId: 'orphan',
          labelIds: [personLabel],
          props: const {},
        ),
      ));
      // No CommitTxn for txnId=2 — the AddNode + Begin should NOT apply.
      // But: the InternString (txnId=1) has no Commit either; that
      // means recovery drops it too. Add a separate committed micro-txn
      // to verify the filter is selective.
      await writeRaw(
        const SequencedWalOp(lsn: 3, txnId: 3, op: BeginTxn()),
      );
      await writeRaw(SequencedWalOp(
        lsn: 4,
        txnId: 3,
        op: const InternString(
          intId: 0,
          value: 'Person',
          kind: StringKind.label,
        ),
      ));
      await writeRaw(
        const SequencedWalOp(lsn: 5, txnId: 3, op: CommitTxn(5)),
      );

      final recovered = await recoverGraphState(store: store);
      // Only the committed micro-txn's interner state survived.
      expect(recovered.strings.labelIdOf('Person'), 0);
      // The orphan AddNode did NOT apply.
      expect(recovered.isNodeVisible(const Vid(0)), isFalse);
    });

    test('openWalBackedGraphDb gives a writable DB whose appends append',
        () async {
      final store = InMemoryWalStore();
      // 1st session — write some data
      {
        final db = _emptyDbBacked(store);
        final lbl = db.internLabel('A');
        await db.runTransaction((txn) {
          txn.addNode(labelIds: [lbl]);
        });
        await db.close();
      }
      final lengthAfterFirst = store.length;
      // 2nd session — open via the convenience helper, mutate more
      store.reopen();
      {
        final db = await openWalBackedGraphDb(store: store);
        // The recovered state knows 'A'.
        expect(db.labelId('A'), 0);
        await db.runTransaction((txn) {
          txn.addNode(labelIds: [0]);
        });
        await db.close();
      }
      expect(store.length, greaterThan(lengthAfterFirst));
      // 3rd session — recovery should see both sessions' writes
      store.reopen();
      final recovered = await recoverGraphState(store: store);
      // Two AddNode commits → two visible nodes.
      var live = 0;
      for (var v = 0; v < recovered.nextVid; v++) {
        if (recovered.isNodeVisible(Vid(v))) live++;
      }
      expect(live, 2);
    });

    test('InternString sequenced before any user op that references the key',
        () async {
      final store = InMemoryWalStore();
      final db = _emptyDbBacked(store);
      final key = db.internPropKey('name');
      await db.runTransaction((txn) {
        final v = txn.addNode(
          labelIds: [db.internLabel('Person')],
          props: {key: const PropString('x')},
        );
        expect(v.value, 0);
      });

      // Re-open + read the raw WAL stream to verify ordering.
      final reader = WalReader(store);
      final ops = await reader.replay().toList();
      // First op should be BeginTxn, then InternString(s) for label
      // and propKey, then AddNode, then CommitTxn.
      expect(ops[0].op, isA<BeginTxn>());
      // Two interns: 'name' (propKey) and 'Person' (label) — order
      // determined by GraphDb's pending list (insertion order: name
      // first, then Person at addNode time).
      expect(ops[1].op, isA<InternString>());
      expect(ops[2].op, isA<InternString>());
      expect(ops[3].op, isA<AddNode>());
      expect(ops[4].op, isA<CommitTxn>());
    });
  });
}
