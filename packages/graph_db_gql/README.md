# graph_db_gql

OpenCypher subset for `graph_db_core` — plan §8 / §14 Phase 3.

## Status

Phase 3 sub-phase 3A (lexer + parser + AST + error reporting for the
read-only subset) is the current focus. See `4_PLAN.md` Phase 3
sub-table for full status.

## Surface

The engine API is added via a Dart extension on `GraphDb`, so the
method looks native once the package is imported:

```dart
import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';

final result = await db.executeQuery(
  'MATCH (n:Person) WHERE n.age > 30 RETURN n.name',
  {},
);
```

Apps that don't import `graph_db_gql` see no `executeQuery` method on
`GraphDb` — the parser and planner are tree-shaken out.

The `flutter_graph_db` umbrella package re-exports this alongside the
engine + WAL for one-import convenience.
