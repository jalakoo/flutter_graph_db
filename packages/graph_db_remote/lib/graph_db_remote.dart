/// `RemoteGraphClient` port + error hierarchy + capability flags +
/// result types for the Flutter-native graph DB (plan §9 / §14 Phase
/// 4A).
///
/// **Port only.** Concrete adapters (Bolt for Neo4j, RESP for
/// FalkorDB) live in sibling packages (`graph_db_remote_neo4j`,
/// `graph_db_remote_falkor`) so consumers pull in only the
/// dependencies they need (plan §12).
library;

export 'src/capabilities.dart';
export 'src/exceptions.dart';
export 'src/id_cache.dart';
export 'src/import_export.dart';
export 'src/remote_graph_client.dart';
export 'src/result_types.dart';
