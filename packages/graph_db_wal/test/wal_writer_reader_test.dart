import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

import 'wal_codec_test.dart' show expectSeqEqual;

void main() {
  test('WalWriter + WalReader round-trip through InMemoryWalStore',
      () async {
    final store = InMemoryWalStore();
    final writer = WalWriter(store);

    const ops = [
      SequencedWalOp(lsn: 0, txnId: 1, op: BeginTxn()),
      SequencedWalOp(
          lsn: 1,
          txnId: 1,
          op: AddNode(
            vid: Vid(0),
            logicalId: 'a-0',
            labelIds: [0],
            props: {3: PropString('Alice')},
          )),
      SequencedWalOp(
          lsn: 2,
          txnId: 1,
          op: AddEdge(
            eid: Eid(0),
            logicalId: 'e-0',
            src: Vid(0),
            dst: Vid(0),
            typeId: 0,
            props: {},
          )),
      SequencedWalOp(lsn: 3, txnId: 1, op: CommitTxn(3)),
    ];

    for (final op in ops) {
      await writer.append(op, durability: Durability.group);
    }

    final reader = WalReader(store);
    final replayed = await reader.replay().toList();
    expect(replayed, hasLength(ops.length));
    for (var i = 0; i < ops.length; i++) {
      expectSeqEqual(replayed[i], ops[i]);
    }
  });

  test('reader stops at the first corrupted frame', () async {
    final store = InMemoryWalStore();
    final writer = WalWriter(store);
    await writer.append(
      const SequencedWalOp(lsn: 0, txnId: 0, op: BeginTxn()),
      durability: Durability.group,
    );
    // Inject a deliberately bad frame between two valid ones: a
    // length-prefix that says "5 bytes body", 5 garbage bytes, and 8
    // zero bytes that won't match xxHash64 of the garbage.
    final bad = Uint8List.fromList(
      [0x05, 1, 2, 3, 4, 5, 0, 0, 0, 0, 0, 0, 0, 0],
    );
    await store.append(bad, durability: Durability.group);
    await writer.append(
      const SequencedWalOp(lsn: 1, txnId: 0, op: CommitTxn(1)),
      durability: Durability.group,
    );

    final reader = WalReader(store);
    final replayed = await reader.replay().toList();
    // Only the first (valid) frame survives — everything past the bad
    // checksum is discarded per §6.5.
    expect(replayed, hasLength(1));
    expect(replayed.first.op, isA<BeginTxn>());
  });

  test('replay fromOffset skips earlier frames', () async {
    final store = InMemoryWalStore();
    final writer = WalWriter(store);
    const codec = WalCodec();

    const first = SequencedWalOp(lsn: 0, txnId: 0, op: BeginTxn());
    const second = SequencedWalOp(lsn: 1, txnId: 0, op: CommitTxn(1));
    final firstFrameLen = codec.encodeFramed(first).length;

    await writer.append(first, durability: Durability.group);
    await writer.append(second, durability: Durability.group);

    final reader = WalReader(store);
    final ops = await reader.replay(fromOffset: firstFrameLen).toList();
    expect(ops, hasLength(1));
    expect(ops.first.op, isA<CommitTxn>());
  });
}
