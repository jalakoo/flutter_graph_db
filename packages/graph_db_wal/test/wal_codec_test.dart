import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

/// Field-by-field equality for [SequencedWalOp] — avoids adding `==`
/// to every [WalOp] subclass.
void expectSeqEqual(SequencedWalOp actual, SequencedWalOp expected) {
  expect(actual.lsn, expected.lsn, reason: 'lsn');
  expect(actual.txnId, expected.txnId, reason: 'txnId');
  final a = actual.op;
  final e = expected.op;
  expect(a.runtimeType, e.runtimeType,
      reason: 'op kind: ${a.runtimeType} vs ${e.runtimeType}');
  switch ((a, e)) {
    case (BeginTxn(), BeginTxn()):
      break;
    case (CommitTxn(:final commitLsn), CommitTxn(commitLsn: final ex)):
      expect(commitLsn, ex);
    case (
        AddNode(
          :final vid,
          :final logicalId,
          :final labelIds,
          :final props,
        ),
        AddNode(
          vid: final exVid,
          logicalId: final exLid,
          labelIds: final exLabels,
          props: final exProps,
        ),
      ):
      expect(vid.value, exVid.value);
      expect(logicalId, exLid);
      expect(labelIds, exLabels);
      expect(props, exProps);
    case (DelNode(:final vid), DelNode(vid: final exVid)):
      expect(vid.value, exVid.value);
    case (
        SetNodeLabels(:final vid, :final added, :final removed),
        SetNodeLabels(
          vid: final exVid,
          added: final exAdded,
          removed: final exRemoved,
        ),
      ):
      expect(vid.value, exVid.value);
      expect(added, exAdded);
      expect(removed, exRemoved);
    case (
        SetNodeProp(:final vid, :final keyId, :final value, :final prevValue),
        SetNodeProp(
          vid: final exVid,
          keyId: final exKey,
          value: final exVal,
          prevValue: final exPrev,
        ),
      ):
      expect(vid.value, exVid.value);
      expect(keyId, exKey);
      expect(value, exVal);
      expect(prevValue, exPrev);
    case (
        DelNodeProp(:final vid, :final keyId),
        DelNodeProp(vid: final exVid, keyId: final exKey),
      ):
      expect(vid.value, exVid.value);
      expect(keyId, exKey);
    case (
        AddEdge(
          :final eid,
          :final logicalId,
          :final src,
          :final dst,
          :final typeId,
          :final props,
        ),
        AddEdge(
          eid: final exEid,
          logicalId: final exLid,
          src: final exSrc,
          dst: final exDst,
          typeId: final exType,
          props: final exProps,
        ),
      ):
      expect(eid.value, exEid.value);
      expect(logicalId, exLid);
      expect(src.value, exSrc.value);
      expect(dst.value, exDst.value);
      expect(typeId, exType);
      expect(props, exProps);
    case (DelEdge(:final eid), DelEdge(eid: final exEid)):
      expect(eid.value, exEid.value);
    case (
        SetEdgeProp(:final eid, :final keyId, :final value, :final prevValue),
        SetEdgeProp(
          eid: final exEid,
          keyId: final exKey,
          value: final exVal,
          prevValue: final exPrev,
        ),
      ):
      expect(eid.value, exEid.value);
      expect(keyId, exKey);
      expect(value, exVal);
      expect(prevValue, exPrev);
    case (
        DelEdgeProp(:final eid, :final keyId),
        DelEdgeProp(eid: final exEid, keyId: final exKey),
      ):
      expect(eid.value, exEid.value);
      expect(keyId, exKey);
    case (
        DeclareConstraint(
          :final name,
          :final labelId,
          :final keyId,
          :final kind,
        ),
        DeclareConstraint(
          name: final exName,
          labelId: final exLabel,
          keyId: final exKey,
          kind: final exKind,
        )
      ):
      expect(name, exName);
      expect(labelId, exLabel);
      expect(keyId, exKey);
      expect(kind, exKind);
    case (DropConstraint(:final name), DropConstraint(name: final exName)):
      expect(name, exName);
    case (
        InternString(:final intId, :final value, :final kind),
        InternString(
          intId: final exId,
          value: final exVal,
          kind: final exKind,
        ),
      ):
      expect(intId, exId);
      expect(value, exVal);
      expect(kind, exKind);
    default:
      fail('unhandled op pair: $a vs $e');
  }
}

void main() {
  const codec = WalCodec();

  group('WalCodec — frame round-trip per op kind', () {
    SequencedWalOp seq(int lsn, int txnId, WalOp op) =>
        SequencedWalOp(lsn: lsn, txnId: txnId, op: op);

    final cases = <SequencedWalOp>[
      seq(0, 1, const BeginTxn()),
      seq(1, 1, const CommitTxn(42)),
      seq(2, 2, const AddNode(
            vid: Vid(7),
            logicalId: 'uuid-7',
            labelIds: [0, 1],
            props: {3: PropString('Alice'), 4: PropInt(34)},
          )),
      seq(3, 2, const DelNode(Vid(7))),
      seq(4, 3, const SetNodeLabels(
            vid: Vid(5),
            added: [2],
            removed: [0],
          )),
      seq(5, 3, const SetNodeProp(
            vid: Vid(5),
            keyId: 3,
            value: PropDouble(1.5),
          )),
      seq(6, 3, const SetNodeProp(
            vid: Vid(5),
            keyId: 4,
            value: PropString('hi'),
            prevValue: PropString('was'),
          )),
      seq(7, 3, const DelNodeProp(vid: Vid(5), keyId: 3)),
      seq(8, 4, const AddEdge(
            eid: Eid(99),
            logicalId: 'uuid-e-99',
            src: Vid(1),
            dst: Vid(2),
            typeId: 0,
            props: {},
          )),
      seq(9, 4, const DelEdge(Eid(99))),
      seq(10, 5, const SetEdgeProp(
            eid: Eid(7),
            keyId: 2,
            value: PropBool(true),
          )),
      seq(11, 5, const DelEdgeProp(eid: Eid(7), keyId: 2)),
      seq(
        12,
        6,
        const DeclareConstraint(
          name: 'unique-name',
          labelId: 0,
          keyId: 1,
          kind: ConstraintKind.unique,
        ),
      ),
      seq(13, 6, const DropConstraint(name: 'unique-name')),
      seq(14, 7, const InternString(
            intId: 3,
            value: 'name',
            kind: StringKind.propKey,
          )),
    ];

    for (final original in cases) {
      test('${original.op.runtimeType}', () {
        final framed = codec.encodeFramed(original);
        // Length-prefix + body + 8-byte checksum.
        expect(framed.length, greaterThan(8));

        // Round-trip via the streaming decoder.
        final decoder = WalDecoder(codec);
        final decoded = decoder.consume(framed).toList();
        expect(decoded, hasLength(1));
        expectSeqEqual(decoded.first, original);
        expect(decoder.terminated, isFalse);
      });
    }
  });

  group('WalCodec — boundary conditions', () {
    test('PropNull, PropList, PropMap round-trip', () {
      final seq = SequencedWalOp(
        lsn: 0,
        txnId: 0,
        op: SetNodeProp(
          vid: const Vid(1),
          keyId: 1,
          value: PropList(const [
            PropInt(1),
            PropString('two'),
            PropNull(),
            PropMap({'a': PropBool(false)}),
          ]),
        ),
      );
      final framed = const WalCodec().encodeFramed(seq);
      final decoded = WalDecoder().consume(framed).single;
      expectSeqEqual(decoded, seq);
    });

    test('streaming decode tolerates split-mid-frame chunks', () {
      const seq = SequencedWalOp(lsn: 0, txnId: 0, op: BeginTxn());
      final framed = codec.encodeFramed(seq);
      final decoder = WalDecoder(codec);
      // Feed one byte at a time — the decoder must buffer.
      final ops = <SequencedWalOp>[];
      for (var i = 0; i < framed.length; i++) {
        ops.addAll(decoder.consume(Uint8List.fromList([framed[i]])));
      }
      expect(ops, hasLength(1));
      expectSeqEqual(ops.first, seq);
    });

    test('multiple frames in one chunk decode in order', () {
      final seqs = [
        const SequencedWalOp(lsn: 0, txnId: 0, op: BeginTxn()),
        const SequencedWalOp(lsn: 1, txnId: 0, op: DelNode(Vid(1))),
        const SequencedWalOp(lsn: 2, txnId: 0, op: CommitTxn(2)),
      ];
      final allBytes = <int>[];
      for (final s in seqs) {
        allBytes.addAll(codec.encodeFramed(s));
      }
      final decoded = WalDecoder()
          .consume(Uint8List.fromList(allBytes))
          .toList();
      expect(decoded, hasLength(3));
      for (var i = 0; i < seqs.length; i++) {
        expectSeqEqual(decoded[i], seqs[i]);
      }
    });

    test('corrupted checksum halts the scan (torn-write semantics)', () {
      final seqs = [
        const SequencedWalOp(lsn: 0, txnId: 0, op: BeginTxn()),
        const SequencedWalOp(lsn: 1, txnId: 0, op: CommitTxn(1)),
      ];
      final bytes = <int>[];
      for (final s in seqs) {
        bytes.addAll(codec.encodeFramed(s));
      }
      // Flip the last byte of the first frame's checksum.
      final firstFrameLen = codec.encodeFramed(seqs.first).length;
      bytes[firstFrameLen - 1] ^= 0xFF;
      final decoder = WalDecoder();
      final out = decoder.consume(Uint8List.fromList(bytes)).toList();
      expect(out, isEmpty);
      expect(decoder.terminated, isTrue);
    });

    test('truncated trailing frame yields earlier frames only', () {
      final seqs = [
        const SequencedWalOp(lsn: 0, txnId: 0, op: BeginTxn()),
        const SequencedWalOp(lsn: 1, txnId: 0, op: CommitTxn(1)),
      ];
      final bytes = <int>[];
      for (final s in seqs) {
        bytes.addAll(codec.encodeFramed(s));
      }
      // Lose the last 2 bytes of the second frame's checksum.
      bytes.removeRange(bytes.length - 2, bytes.length);
      final decoder = WalDecoder();
      final out = decoder.consume(Uint8List.fromList(bytes)).toList();
      expect(out, hasLength(1));
      expectSeqEqual(out.single, seqs.first);
      // The decoder is *not* terminated — it just doesn't have enough
      // bytes for the trailing frame yet. Recovery treats end-of-stream
      // here as "no more committed entries" (§6.5).
      expect(decoder.terminated, isFalse);
    });
  });
}
