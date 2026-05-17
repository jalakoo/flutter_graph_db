/// Abstract bytes-in / bytes-out transport so the adapter is
/// testable without a real socket.
///
/// Real connections wrap a `dart:io` `Socket` (TCP) or
/// `SecureSocket` (TLS); tests wrap a controllable
/// `StreamController` + `BytesBuilder` pair.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

abstract interface class BoltTransport {
  Stream<Uint8List> get input;
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

/// Production transport — wraps a `dart:io` `Socket`. Native targets
/// only; web has no `Socket`, and Bolt doesn't currently support
/// browser transports (Neo4j ships a separate `bolt+ws` WebSocket
/// scheme that's a Phase 8 concern).
class SocketBoltTransport implements BoltTransport {
  final Socket _socket;
  SocketBoltTransport(this._socket);

  static Future<SocketBoltTransport> connect(
    String host,
    int port, {
    bool useTls = false,
    SecurityContext? context,
  }) async {
    final socket = useTls
        ? await SecureSocket.connect(host, port, context: context)
        : await Socket.connect(host, port);
    return SocketBoltTransport(socket);
  }

  @override
  Stream<Uint8List> get input =>
      _socket.cast<List<int>>().map(Uint8List.fromList);

  @override
  Future<void> write(Uint8List bytes) async {
    _socket.add(bytes);
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    await _socket.close();
  }
}
