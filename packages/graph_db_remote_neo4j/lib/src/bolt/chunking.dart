/// Bolt's 16-bit chunked message framing.
///
/// One logical message is split into one or more chunks:
///   [u16 length] [length bytes of payload] ... [u16 zero terminator]
///
/// Chunk lengths are 1..0xFFFF. The terminator `00 00` ends the
/// message. Multiple messages share the same stream; the boundary is
/// the terminator.
library;

import 'dart:async';
import 'dart:typed_data';

const int kMaxChunkBytes = 0xFFFF;

/// Frames [payload] (a single full message body) into chunked bytes
/// ready to write to the socket.
Uint8List frameMessage(Uint8List payload) {
  final out = BytesBuilder(copy: false);
  var offset = 0;
  while (offset < payload.length) {
    final chunkLen = (payload.length - offset).clamp(1, kMaxChunkBytes);
    final hdr = ByteData(2)..setUint16(0, chunkLen);
    out.add(hdr.buffer.asUint8List());
    out.add(Uint8List.sublistView(payload, offset, offset + chunkLen));
    offset += chunkLen;
  }
  // terminator
  out.addByte(0);
  out.addByte(0);
  return out.takeBytes();
}

/// Stateful de-chunker — feed it bytes off the wire; it yields full
/// message payloads (one [Uint8List] per logical message) as
/// terminators arrive.
class ChunkDecoder {
  final BytesBuilder _current = BytesBuilder(copy: false);
  final List<int> _buf = [];
  int? _pendingChunkLen;

  /// Consumes [bytes] and emits any newly-completed message payloads
  /// in order.
  Iterable<Uint8List> consume(Uint8List bytes) sync* {
    _buf.addAll(bytes);
    while (true) {
      if (_pendingChunkLen == null) {
        if (_buf.length < 2) return;
        final n = (_buf[0] << 8) | _buf[1];
        _buf.removeRange(0, 2);
        if (n == 0) {
          yield _current.takeBytes();
          continue;
        }
        _pendingChunkLen = n;
      }
      final need = _pendingChunkLen!;
      if (_buf.length < need) return;
      _current.add(Uint8List.fromList(_buf.sublist(0, need)));
      _buf.removeRange(0, need);
      _pendingChunkLen = null;
    }
  }
}

/// Stream-based variant — wraps a `Stream<List<int>>` (e.g. a Socket)
/// into a `Stream<Uint8List>` of complete message payloads.
Stream<Uint8List> dechunkedMessages(Stream<List<int>> source) async* {
  final decoder = ChunkDecoder();
  await for (final chunk in source) {
    yield* Stream.fromIterable(
      decoder.consume(Uint8List.fromList(chunk)),
    );
  }
}
