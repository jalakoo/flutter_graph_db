/// Bytes-in / bytes-out transport for the FalkorDB adapter.
library;

import 'dart:io';
import 'dart:typed_data';

abstract interface class RespTransport {
  Stream<Uint8List> get input;
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

class SocketRespTransport implements RespTransport {
  final Socket _socket;
  SocketRespTransport(this._socket);

  static Future<SocketRespTransport> connect(
    String host,
    int port, {
    bool useTls = false,
    SecurityContext? context,
  }) async {
    final socket = useTls
        ? await SecureSocket.connect(host, port, context: context)
        : await Socket.connect(host, port);
    return SocketRespTransport(socket);
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
  Future<void> close() => _socket.close();
}
