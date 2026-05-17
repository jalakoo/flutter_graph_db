# flutter_graph_db

Umbrella package — the one-import entry point for the Flutter-native
graph database. Re-exports:

- `graph_db_core` — engine (CSR, properties, applicator, public API)
- `graph_db_wal` — WAL persistence + recovery
- `graph_db_gql` — OpenCypher subset (parser, planner, executor)

## Quick start

```yaml
dependencies:
  flutter_graph_db: ^0.1.0
```

```dart
import 'package:flutter_graph_db/flutter_graph_db.dart';
import 'package:graph_db_wal/io_wal_store.dart'; // native-only adapter
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final store = IoWalStore('${dir.path}/graph.wal');
  final db = await openWalBackedGraphDb(store: store);

  await db.runTransaction((txn) {
    final alice = txn.addNode(labelIds: [db.internLabel('Person')], props: {
      db.internPropKey('name'): const PropString('Alice'),
    });
  });

  final result = await db.executeQuery(
    'MATCH (n:Person) WHERE n.age > 30 RETURN n.name',
    {},
  );

  runApp(MyApp(db: db, result: result));
}
```

## When to skip the umbrella

- You only need the primitive read/write API — depend on `graph_db_core` directly.
- You want a specific sub-package version newer than what the umbrella pins.
- You're publishing a library that depends on this — explicit deps document your real surface needs.
