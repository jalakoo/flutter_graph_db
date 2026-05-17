# flutter_graph_db

[![ci](https://github.com/jalakoo/flutter_graph_db/actions/workflows/ci.yaml/badge.svg)](https://github.com/jalakoo/flutter_graph_db/actions/workflows/ci.yaml)

A pure-Dart, Flutter-native embedded graph database. One in-process
engine that runs on iOS, Android, macOS, Windows, Linux, and the
browser (`dart2js` + `dart2wasm`) from the same code path.

## Contents

- [What's in the box](#whats-in-the-box)
- [Quick start](#quick-start)
- [Layout](#layout)
- [Tests](#tests)
- [Key design points](#key-design-points)

## What's in the box

Nine packages plus a Flutter example app.

| Package | Role |
|---|---|
| [`flutter_graph_db`](packages/flutter_graph_db) | **Umbrella** — depend on this once, get engine + WAL + GQL re-exported. Start here. |
| [`graph_db_core`](packages/graph_db_core) | Engine — CSR topology, columnar property store, transactional applicator, public read / write API. |
| [`graph_db_wal`](packages/graph_db_wal) | WAL schema, codec, recovery, and the byte-range `WalStore` port. Ships in-memory, native (`dart:io`), and IndexedDB adapters. |
| [`graph_db_gql`](packages/graph_db_gql) | OpenCypher subset — parser, planner, push-based executor. Exposed via `GraphDb.executeQuery(...)` extension. |
| [`graph_db_remote`](packages/graph_db_remote) | `RemoteGraphClient` interface — sync-target port. |
| [`graph_db_remote_neo4j`](packages/graph_db_remote_neo4j) | Bolt v4/v5 client adapter for Neo4j. |
| [`graph_db_remote_falkor`](packages/graph_db_remote_falkor) | RESP client adapter for FalkorDB. |
| [`graph_db_sync`](packages/graph_db_sync) | Push-only sync engine — drains local WAL to remote targets. |
| [`graph_db_bench`](packages/graph_db_bench) | R-MAT generators + latency / GC-event harness for repeatable perf measurement. |
| [`example/`](example) | Flutter sample app — Material 3, six tabs, real CRUD, WAL-backed persistence, in-app perf bench. |

## Quick start

Use the engine in your own app — see the
[umbrella package README](packages/flutter_graph_db/README.md) for the
full consumer guide (install, in-memory quickstart, web / mobile /
desktop persistence wiring, snapshot cycle, sub-package map).

Tour the engine via the demo:

```sh
cd example
flutter pub get
flutter run
```

## Layout

```
flutter_graph_db/
  README.md
  analysis_options.yaml            ← shared lints baseline
  packages/
    flutter_graph_db/              ← umbrella package (start here)
    graph_db_core/                 ← engine — CSR, properties, applicator
    graph_db_wal/                  ← WAL persistence (io, in-mem, IndexedDB)
    graph_db_gql/                  ← OpenCypher subset
    graph_db_remote/               ← RemoteGraphClient interface
    graph_db_remote_neo4j/         ← Neo4j Bolt adapter
    graph_db_remote_falkor/        ← FalkorDB RESP adapter
    graph_db_sync/                 ← push-only sync engine
    graph_db_bench/                ← perf measurement harness
  example/                         ← Flutter demo (iOS / Android / web / desktop)
```

Each package resolves independently — no Dart workspace gate. SDK
floor is Dart 3.5+.

## Tests

Per-package:

```sh
cd packages/<name>
dart pub get
dart analyze
dart test
```

Full sweep (run from repo root):

```sh
for p in packages/*/; do
  (cd "$p" && dart pub get && dart test)
done
cd example && flutter test
```

The repo currently runs ~370 unit tests across the nine packages plus
15 widget tests in the example app. The `graph_db_wal` IDB adapter
has an additional 5 browser-only tests under `dart test -p chrome`.

## Key design points

- **CSR topology** — `Uint32List` row pointer / column index / edge id
  arrays in both directions. Allocation-free reads on the hot path.
  Web-safe (no `Int64List` / `Uint64List` reliance).
- **Columnar property store** — per-key typed columns (`Float64List`,
  `Uint8List`, `Uint32List`, `List<String>`). Raw on the read path,
  boxed to `PropValue` only at the public API boundary.
- **Per-vid delta overlay + worker-isolate merge** — mutations land in
  an overlay; on a size threshold, a background isolate copy-folds it
  into a fresh CSR and the main isolate installs via pointer swap.
  Web targets fall back to a synchronous main-isolate fold.
- **WAL persistence** — CBOR + length-prefix framing + xxHash64
  checksum per record. Recovery is two-pass redo-with-commit. Three
  adapters in tree: in-memory, native file (`dart:io`), and IndexedDB.
- **GQL surface** — OpenCypher read-subset via a Dart extension on
  `GraphDb`; planner emits a push-based operator tree with an LRU
  plan cache.
- **Sync engine** — push-only WAL drain → bulk import to remote
  targets; per-target HWM + quarantine queue; `fullExport` seeding
  mode for new targets.
