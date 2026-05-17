# graph_db_gql

OpenCypher subset for `graph_db_core` — lexer, parser, AST, planner,
push-based executor, and an LRU plan cache. Surfaced via a Dart
extension on `GraphDb` so the call site looks native:

```dart
import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';

final result = await db.executeQuery(
  'MATCH (n:Person) WHERE n.age > 30 RETURN n.name AS name',
  {},
);
for (final row in result.rows) {
  print(row.values['name']);
}
```

## Contents

- [Tree-shaking](#tree-shaking)
- [Plan cache](#plan-cache)
- [Subset coverage](#subset-coverage)

## Tree-shaking

The `executeQuery` extension is opt-in — apps that don't import
`graph_db_gql` see no method added to `GraphDb`, and the parser /
planner / executor get tree-shaken out of the release build. Pay only
for what you use.

The [`flutter_graph_db`](../flutter_graph_db) umbrella re-exports this
alongside the engine + WAL for one-import convenience.

## Plan cache

A per-`GraphDb` LRU plan cache (default size: 128 entries) keyed by
`(query string, parameter shape)` is attached transparently via an
`Expando`. Re-running the same query string skips lexing / parsing /
planning. Cache size is tunable:

```dart
GqlPlanCache.installOn(db, capacity: 1024);
```

## Subset coverage

The executor implements the read-only OpenCypher subset most embedded
graph workloads need. Coverage is currently:

- `MATCH` with node patterns (`(:Label)`), relationship patterns
  (`-[:TYPE]->`), and chains.
- `WHERE` with comparison, boolean, arithmetic, `IN`, `IS NULL`,
  function calls.
- `RETURN` with `AS` aliases, `DISTINCT`, projection expressions.
- `ORDER BY`, `SKIP`, `LIMIT`.
- Parameters via the `{params: …}` map argument.

Out of scope today: write clauses (`CREATE` / `MERGE` / `DELETE`),
optional matches, aggregations beyond `COUNT`, path functions.
Write-side mutations go through `GraphDb.runTransaction` directly.
