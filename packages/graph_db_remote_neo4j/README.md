# graph_db_remote_neo4j

`RemoteGraphClient` adapter for Neo4j over the Bolt v4 / v5 binary
protocol.

Wraps a hand-rolled `PackStream` codec, chunked framing, and the
handshake / `HELLO` / `RUN` / `PULL` message flow — no community
package dependency, so the wire layer is auditable in tree.

## Usage

```dart
import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_remote_neo4j/graph_db_remote_neo4j.dart';

final client = Neo4jBoltClient(
  host: 'localhost',
  port: 7687,
  auth: BoltBasicAuth(user: 'neo4j', password: 'secret'),
);

await client.bulkImport(myImportOpStream);
final result = await client.executeReadQuery(
  'MATCH (n:Person) RETURN n.name',
  {},
);
```

Plug into the sync engine:

```dart
final target = SyncTarget(
  name: 'prod-neo4j',
  client: client,
  seedingMode: SeedingMode.incremental,
);
final engine = SyncEngine(db: db, walStore: store, targets: [target]);
await engine.syncOnce();
```

## Status notes

Live-backend integration tests (Docker'd Neo4j) are exercised
manually. Wire the bring-up into your own CI lane if you depend on
this adapter for production sync.
