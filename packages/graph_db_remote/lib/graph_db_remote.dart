/// `RemoteGraphClient` interface, error hierarchy, and capability flags
/// for the Flutter-native graph DB (plan §9).
///
/// **Skeleton.** Implementation lands in Phase 4 per plan §14. The
/// concrete adapters (Bolt for Neo4j, RESP for FalkorDB) live in
/// sibling packages (`graph_db_remote_neo4j`, `graph_db_remote_falkor`)
/// so consumers pull in only the dependencies they need (plan §12).
library;
