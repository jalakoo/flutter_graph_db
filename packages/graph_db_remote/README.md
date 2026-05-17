# graph_db_remote

`RemoteGraphClient` interface + result types + error hierarchy +
capability flags. The shared contract every remote-graph adapter
implements.

Depend on this directly when you're **building** a custom remote
adapter (a backend not yet in tree). Consumers pushing to Neo4j or
FalkorDB use [`graph_db_remote_neo4j`](../graph_db_remote_neo4j) or
[`graph_db_remote_falkor`](../graph_db_remote_falkor), which both
depend on this transitively.

## What it exposes

- **`RemoteGraphClient`** — the abstract interface every adapter
  implements: `bulkImport(Stream<ImportOp>)`, `executeReadQuery`,
  `executeWriteQuery`, `listConstraints` (optional), …
- **`ImportOp` hierarchy** — `ImportNode` / `ImportEdge` shapes used
  by the sync engine and bulk-load paths.
- **`RemoteException` hierarchy** — `RemoteConnectionException`,
  `RemoteAuthException`, `RemoteConstraintViolation`,
  `RemoteQueryException`, etc.
- **`RemoteCapabilities`** — feature flags so callers can detect what
  a given backend supports (transactions, listConstraints, parameter
  styles, …).
- **`IdCache`** — bidirectional LRU for translating local logical ids
  ↔ remote ids without round-tripping.

## Building a new adapter

1. Implement `RemoteGraphClient` for your protocol.
2. Surface `RemoteCapabilities` honestly — the sync engine and bench
   harness key off these.
3. Map your backend's errors into the `RemoteException` hierarchy.
4. Ship test fixtures (`fake_remote_client.dart` patterns exist in
   the two in-tree adapters as reference).

See [`graph_db_remote_neo4j`](../graph_db_remote_neo4j) and
[`graph_db_remote_falkor`](../graph_db_remote_falkor) for full
example implementations.
