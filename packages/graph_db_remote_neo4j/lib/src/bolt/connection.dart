/// A live Bolt session — handshake + chunked I/O on top of a
/// [BoltTransport].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_remote/graph_db_remote.dart';

import 'chunking.dart';
import 'handshake.dart';
import 'messages.dart';
import 'packstream.dart';
import 'transport.dart';

class BoltConnection {
  final BoltTransport transport;
  late final Stream<Uint8List> _messages;
  StreamIterator<Uint8List>? _iter;
  ({int major, int minor})? negotiatedVersion;
  bool _closed = false;

  BoltConnection(this.transport);

  /// Performs the magic + version handshake, returns the negotiated
  /// version. Throws [ConnectionException] on rejection.
  Future<({int major, int minor})> handshake([
    List<({int major, int minor})> offered = kDefaultVersions,
  ]) async {
    await transport.write(buildHandshake(offered));
    // First 4 bytes back are the version selection.
    final raw = transport.input;
    final iter = StreamIterator<Uint8List>(raw);
    // Read at least 4 bytes — the transport may deliver them as one
    // chunk or split.
    final buf = BytesBuilder(copy: false);
    while (buf.length < 4) {
      if (!await iter.moveNext()) {
        throw const ConnectionException(
            'Bolt handshake: server closed before reply');
      }
      buf.add(iter.current);
    }
    final all = buf.takeBytes();
    final version = parseHandshakeResponse(all);
    if (version == null) {
      throw const ConnectionException(
          'Bolt handshake: server rejected every offered version');
    }
    negotiatedVersion = version;
    // Wrap remaining bytes (post-handshake) + the rest of the stream
    // into the chunked-message decoder.
    final leftover = all.sublist(4);
    final remaining = StreamController<Uint8List>();
    if (leftover.isNotEmpty) {
      remaining.add(leftover);
    }
    // Pipe the iter's remaining items into the controller without
    // blocking.
    () async {
      while (await iter.moveNext()) {
        remaining.add(iter.current);
      }
      await remaining.close();
    }();
    _messages = dechunkedMessages(remaining.stream);
    _iter = StreamIterator<Uint8List>(_messages);
    return version;
  }

  /// Encodes + chunk-frames + writes [message]. Caller awaits the
  /// reply via [receive].
  Future<void> send(BoltStruct message) async {
    _ensureOpen();
    final encoder = PackStreamEncoder()..writeValue(message);
    final payload = encoder.takeBytes();
    final framed = frameMessage(payload);
    await transport.write(framed);
  }

  /// Awaits the next server message. Throws [ProtocolException] on
  /// unexpected EOF.
  Future<BoltStruct> receive() async {
    _ensureOpen();
    final iter = _iter!;
    if (!await iter.moveNext()) {
      throw const ProtocolException('Bolt stream closed unexpectedly');
    }
    final payload = iter.current;
    final decoder = PackStreamDecoder(payload);
    final v = decoder.readValue();
    if (v is! BoltStruct) {
      throw ProtocolException(
          'expected Bolt struct, got ${v.runtimeType}');
    }
    return v;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await send(buildGoodbye());
    } catch (_) {
      // best-effort goodbye
    }
    await transport.close();
  }

  void _ensureOpen() {
    if (_closed) throw const ConnectionException('Bolt connection is closed');
  }
}
