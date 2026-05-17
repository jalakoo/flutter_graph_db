/// Neo4j adapter — Bolt v4/v5 over `dart:io` `Socket` /
/// `SecureSocket` implementing [`RemoteGraphClient`] (plan §9 /
/// §14 Phase 4B–4C).
library;

export 'src/bolt/chunking.dart' show ChunkDecoder, frameMessage;
export 'src/bolt/connection.dart' show BoltConnection;
export 'src/bolt/handshake.dart'
    show buildHandshake, parseHandshakeResponse, kDefaultVersions;
export 'src/bolt/messages.dart'
    show
        BoltMessage,
        buildBegin,
        buildCommit,
        buildGoodbye,
        buildHello,
        buildPull,
        buildReset,
        buildRollback,
        buildRun,
        boltNodeTag,
        boltPathTag,
        boltRelTag;
export 'src/bolt/packstream.dart'
    show
        BoltStruct,
        PackStreamDecoder,
        PackStreamEncoder,
        PackStreamException;
export 'src/bolt/transport.dart'
    show BoltTransport, SocketBoltTransport;
export 'src/neo4j_client.dart' show Neo4jClient, Neo4jClientConfig;
