import 'dart:typed_data';

import 'package:cbor/simple.dart';
import 'package:graph_db_core/graph_db_core.dart';
import 'package:xxh3/xxh3.dart';

/// Codec for one framed WAL entry.
///
/// **Frame layout:**
///
/// ```text
/// [ varint: body length ][ body bytes (CBOR) ][ xxHash64(body), 8 bytes BE ]
/// ```
///
/// **Encoding** uses `package:cbor`'s simple codec everywhere. A
/// dep-audit found that hand-rolling `AddNode` / `AddEdge` /
/// `SetNodeProp` is ~5× faster than `package:cbor` on iOS AOT — that
/// optimisation is a follow-up, but the schema laid down here
/// (text-keyed maps with `op` naming the kind) matches what
/// `handRollAddEdgeCbor` produces, so the optimised encoders can
/// drop in without changing the on-disk format.
///
/// **Torn-write detection.** The decoder validates the xxHash64
/// checksum; mismatch terminates the scan and discards everything past
/// the first bad entry. Truncation at any point inside a frame
/// is treated the same.
///
/// **Web note.** Dart ints on web are 53-bit; the 64-bit checksum write
/// uses `>>>` so it's correct on native, but reading back on web would
/// lose the top 11 bits. The web `WalStore` adapter will need
/// a 53-bit-safe checksum representation, or the framing format will
/// switch to two 32-bit words.
class WalCodec {
  const WalCodec();

  /// Encodes [seq] into a self-framed byte sequence: varint length +
  /// CBOR body + xxHash64 checksum. The returned [Uint8List] is what
  /// the WAL writer appends to the [WalStore].
  Uint8List encodeFramed(SequencedWalOp seq) {
    final body = _encodeBody(seq);
    final lenBytes = _encodeVarint(body.length);
    final out = Uint8List(lenBytes.length + body.length + 8);
    out.setRange(0, lenBytes.length, lenBytes);
    out.setRange(lenBytes.length, lenBytes.length + body.length, body);
    final checksumOffset = lenBytes.length + body.length;
    _writeUint64Be(out, checksumOffset, xxh3(body));
    return out;
  }

  /// Decodes one CBOR body (no framing) into a [SequencedWalOp]. Useful
  /// in tests and in the [WalDecoder]'s inner loop.
  SequencedWalOp decodeBody(Uint8List body) {
    final raw = cbor.decode(body);
    if (raw is! Map) {
      throw const FormatException('WalOp body must be a CBOR map');
    }
    return _seqFromMap(raw);
  }

  // -------------------------------------------------------------------- body

  Uint8List _encodeBody(SequencedWalOp seq) =>
      Uint8List.fromList(cbor.encode(_seqToMap(seq)));

  Map<String, dynamic> _seqToMap(SequencedWalOp seq) {
    final op = seq.op;
    return switch (op) {
      BeginTxn() => {'op': 'BeginTxn', 'lsn': seq.lsn, 'txnId': seq.txnId},
      CommitTxn(:final commitLsn) => {
          'op': 'CommitTxn',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'commitLsn': commitLsn,
        },
      AddNode(
        :final vid,
        :final logicalId,
        :final labelIds,
        :final props,
      ) =>
        {
          'op': 'AddNode',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'vid': vid.value,
          'lid': logicalId,
          'labels': labelIds,
          'props': _propsToCbor(props),
        },
      DelNode(:final vid) => {
          'op': 'DelNode',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'vid': vid.value,
        },
      SetNodeLabels(:final vid, :final added, :final removed) => {
          'op': 'SetNodeLabels',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'vid': vid.value,
          'added': added,
          'removed': removed,
        },
      SetNodeProp(
        :final vid,
        :final keyId,
        :final value,
        :final prevValue,
      ) =>
        {
          'op': 'SetNodeProp',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'vid': vid.value,
          'keyId': keyId,
          'value': _propToCbor(value),
          if (prevValue != null) 'prevValue': _propToCbor(prevValue),
        },
      DelNodeProp(:final vid, :final keyId) => {
          'op': 'DelNodeProp',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'vid': vid.value,
          'keyId': keyId,
        },
      AddEdge(
        :final eid,
        :final logicalId,
        :final src,
        :final dst,
        :final typeId,
        :final props,
      ) =>
        {
          'op': 'AddEdge',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'eid': eid.value,
          'lid': logicalId,
          'src': src.value,
          'dst': dst.value,
          'type': typeId,
          'props': _propsToCbor(props),
        },
      DelEdge(:final eid) => {
          'op': 'DelEdge',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'eid': eid.value,
        },
      SetEdgeProp(
        :final eid,
        :final keyId,
        :final value,
        :final prevValue,
      ) =>
        {
          'op': 'SetEdgeProp',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'eid': eid.value,
          'keyId': keyId,
          'value': _propToCbor(value),
          if (prevValue != null) 'prevValue': _propToCbor(prevValue),
        },
      DelEdgeProp(:final eid, :final keyId) => {
          'op': 'DelEdgeProp',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'eid': eid.value,
          'keyId': keyId,
        },
      DeclareConstraint(
        :final name,
        :final labelId,
        :final keyId,
        :final kind,
      ) =>
        {
          'op': 'DeclareConstraint',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'name': name,
          'labelId': labelId,
          'keyId': keyId,
          'kind': kind.name,
        },
      DropConstraint(:final name) => {
          'op': 'DropConstraint',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'name': name,
        },
      InternString(:final intId, :final value, :final kind) => {
          'op': 'InternString',
          'lsn': seq.lsn,
          'txnId': seq.txnId,
          'intId': intId,
          'value': value,
          'kind': kind.name,
        },
    };
  }

  SequencedWalOp _seqFromMap(Map<dynamic, dynamic> m) {
    final tag = m['op'];
    final lsn = m['lsn'] as int;
    final txnId = m['txnId'] as int;
    final WalOp op = switch (tag) {
      'BeginTxn' => const BeginTxn(),
      'CommitTxn' => CommitTxn(m['commitLsn'] as int),
      'AddNode' => AddNode(
          vid: Vid(m['vid'] as int),
          logicalId: m['lid'] as String,
          labelIds: (m['labels'] as List).cast<int>(),
          props: _propsFromCbor(m['props']),
        ),
      'DelNode' => DelNode(Vid(m['vid'] as int)),
      'SetNodeLabels' => SetNodeLabels(
          vid: Vid(m['vid'] as int),
          added: (m['added'] as List).cast<int>(),
          removed: (m['removed'] as List).cast<int>(),
        ),
      'SetNodeProp' => SetNodeProp(
          vid: Vid(m['vid'] as int),
          keyId: m['keyId'] as int,
          value: _propFromCbor(m['value']),
          prevValue: m.containsKey('prevValue')
              ? _propFromCbor(m['prevValue'])
              : null,
        ),
      'DelNodeProp' => DelNodeProp(
          vid: Vid(m['vid'] as int),
          keyId: m['keyId'] as int,
        ),
      'AddEdge' => AddEdge(
          eid: Eid(m['eid'] as int),
          logicalId: m['lid'] as String,
          src: Vid(m['src'] as int),
          dst: Vid(m['dst'] as int),
          typeId: m['type'] as int,
          props: _propsFromCbor(m['props']),
        ),
      'DelEdge' => DelEdge(Eid(m['eid'] as int)),
      'SetEdgeProp' => SetEdgeProp(
          eid: Eid(m['eid'] as int),
          keyId: m['keyId'] as int,
          value: _propFromCbor(m['value']),
          prevValue: m.containsKey('prevValue')
              ? _propFromCbor(m['prevValue'])
              : null,
        ),
      'DelEdgeProp' => DelEdgeProp(
          eid: Eid(m['eid'] as int),
          keyId: m['keyId'] as int,
        ),
      'DeclareConstraint' => DeclareConstraint(
          name: m['name'] as String,
          labelId: m['labelId'] as int,
          keyId: m['keyId'] as int,
          kind: ConstraintKind.values
              .firstWhere((k) => k.name == m['kind'] as String),
        ),
      'DropConstraint' => DropConstraint(name: m['name'] as String),
      'InternString' => InternString(
          intId: m['intId'] as int,
          value: m['value'] as String,
          kind: _kindFromName(m['kind'] as String),
        ),
      _ => throw FormatException('unknown WalOp tag: $tag'),
    };
    return SequencedWalOp(lsn: lsn, txnId: txnId, op: op);
  }

  // ----------------------------------------------------------- PropValue ↔ CBOR

  Map<int, dynamic> _propsToCbor(Map<int, PropValue> ps) =>
      ps.map((k, v) => MapEntry(k, _propToCbor(v)));

  Map<int, PropValue> _propsFromCbor(dynamic c) {
    if (c is! Map) {
      throw const FormatException('props must be a CBOR map');
    }
    return c.map((k, v) => MapEntry(k as int, _propFromCbor(v)));
  }

  dynamic _propToCbor(PropValue v) => switch (v) {
        PropInt(:final value) => value,
        PropDouble(:final value) => value,
        PropString(:final value) => value,
        PropBool(:final value) => value,
        PropNull() => null,
        PropList(:final values) =>
          values.map(_propToCbor).toList(growable: false),
        PropMap(:final values) =>
          values.map((k, v) => MapEntry(k, _propToCbor(v))),
      };

  PropValue _propFromCbor(dynamic c) {
    if (c == null) return const PropNull();
    if (c is bool) return PropBool(c);
    if (c is int) return PropInt(c);
    if (c is double) return PropDouble(c);
    if (c is String) return PropString(c);
    if (c is List) {
      return PropList(c.map(_propFromCbor).toList(growable: false));
    }
    if (c is Map) {
      return PropMap(c.map(
        (k, v) => MapEntry(k.toString(), _propFromCbor(v)),
      ));
    }
    throw FormatException('unknown CBOR shape for PropValue: ${c.runtimeType}');
  }

  StringKind _kindFromName(String name) => switch (name) {
        'label' => StringKind.label,
        'edgeType' => StringKind.edgeType,
        'propKey' => StringKind.propKey,
        _ => throw FormatException('unknown StringKind: $name'),
      };
}

// ============================================================ varint + u64

Uint8List _encodeVarint(int v) {
  if (v < 0) throw ArgumentError.value(v, 'v', 'varint must be non-negative');
  final out = <int>[];
  var n = v;
  while (n >= 0x80) {
    out.add((n & 0x7F) | 0x80);
    n >>>= 7;
  }
  out.add(n);
  return Uint8List.fromList(out);
}

void _writeUint64Be(Uint8List buf, int offset, int v) {
  buf[offset] = (v >>> 56) & 0xFF;
  buf[offset + 1] = (v >>> 48) & 0xFF;
  buf[offset + 2] = (v >>> 40) & 0xFF;
  buf[offset + 3] = (v >>> 32) & 0xFF;
  buf[offset + 4] = (v >>> 24) & 0xFF;
  buf[offset + 5] = (v >>> 16) & 0xFF;
  buf[offset + 6] = (v >>> 8) & 0xFF;
  buf[offset + 7] = v & 0xFF;
}

int readUint64Be(Uint8List buf, int offset) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | buf[offset + i];
  }
  return v;
}

// ============================================================ stream decoder

/// Stateful decoder that consumes byte chunks from a [WalStore] and
/// yields [SequencedWalOp]s. Halts at the first bad checksum or
/// truncated frame.
class WalDecoder {
  final WalCodec _codec;
  final List<int> _buf = [];
  bool _terminated = false;

  WalDecoder([this._codec = const WalCodec()]);

  /// `true` after a torn-write / bad-checksum frame was seen. Further
  /// [consume] calls produce nothing.
  bool get terminated => _terminated;

  Iterable<SequencedWalOp> consume(Uint8List chunk) sync* {
    if (_terminated) return;
    _buf.addAll(chunk);

    var pos = 0;
    while (true) {
      // Try varint at pos.
      var v = 0;
      var shift = 0;
      var i = pos;
      var varintOk = false;
      while (i < _buf.length) {
        final b = _buf[i++];
        v |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) {
          varintOk = true;
          break;
        }
        shift += 7;
        if (shift > 63) {
          _terminate();
          return;
        }
      }
      if (!varintOk) break; // need more bytes for the length
      final varintLen = i - pos;
      final bodyLen = v;
      final frameEnd = pos + varintLen + bodyLen + 8;
      if (frameEnd > _buf.length) break; // need more bytes for body+checksum

      // Slice the body and validate the checksum.
      final bodyStart = pos + varintLen;
      final body = Uint8List.fromList(_buf.sublist(bodyStart, bodyStart + bodyLen));
      final csOffset = bodyStart + bodyLen;
      final expected = readUint64Be(
        Uint8List.fromList(_buf.sublist(csOffset, csOffset + 8)),
        0,
      );
      final actual = xxh3(body);
      if (actual != expected) {
        _terminate();
        return;
      }
      yield _codec.decodeBody(body);
      pos = frameEnd;
    }

    // Compact: drop consumed prefix, keep tail for the next chunk.
    if (pos > 0) {
      _buf.removeRange(0, pos);
    }
  }

  void _terminate() {
    _terminated = true;
    _buf.clear();
  }
}
