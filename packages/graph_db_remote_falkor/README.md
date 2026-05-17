# graph_db_remote_falkor

`RemoteGraphClient` adapter for [FalkorDB](https://www.falkordb.com)
over RESP2 (the Redis text protocol).

Hand-rolled RESP encoder / decoder plus a thin command builder for
`GRAPH.QUERY` / `GRAPH.RO_QUERY`. No external Redis client dependency
— the wire layer is auditable in tree.

## Usage

```dart
import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_remote_falkor/graph_db_remote_falkor.dart';

final client = FalkorClient(
  host: 'localhost',
  port: 6379,
  graphName: 'social',
);

await client.bulkImport(myImportOpStream);
final result = await client.executeReadQuery(
  'MATCH (n:Person) RETURN n.name',
  {},
);
```

Plug into the sync engine the same way as any other
`RemoteGraphClient` — see
[`graph_db_remote_neo4j`](../graph_db_remote_neo4j) for the pattern.

## Status notes

Live-backend integration tests (Docker'd FalkorDB) are exercised
manually. Wire the bring-up into your own CI lane if you depend on
this adapter for production sync.
