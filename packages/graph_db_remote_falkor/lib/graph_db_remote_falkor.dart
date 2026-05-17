/// FalkorDB adapter — RESP2 over `dart:io` `Socket` /
/// `SecureSocket` implementing [`RemoteGraphClient`].
library;

export 'src/falkor_client.dart' show FalkorClient, FalkorClientConfig;
export 'src/resp/resp.dart'
    show RespDecoder, RespError, RespException, encodeCommand;
export 'src/resp/transport.dart' show RespTransport, SocketRespTransport;
