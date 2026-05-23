# flutter_graph_db

Embedded, Flutter-native graph database. One in-process engine that
runs on iOS, Android, macOS, Windows, Linux, and the browser
(`dart2js` + `dart2wasm`) from the same code path.

This is the **umbrella package** — depend on it once, import one
file, and you get the engine + WAL persistence + an OpenCypher query
layer in tree. Adapters that not every app needs (Neo4j / FalkorDB /
sync) live in separate packages and are imported explicitly.

## Contents

- [Install](#install)
- [Quick start — in-memory](#quick-start--in-memory)
- [Read-your-writes — the merge lifecycle](#read-your-writes--the-merge-lifecycle)
- [Mobile / desktop persistence](#mobile--desktop-persistence-ios--android--macos--windows--linux)
- [Web persistence](#web-persistence-chrome--safari--firefox)
- [Snapshot + compact cycle](#snapshot--compact-cycle-long-running-apps)
- [Sub-packages — when to depend directly](#sub-packages--when-to-depend-directly)
- [Benchmarking](#benchmarking)
- [Run the example app](#run-the-example-app)

## Install

Local git dependency (the only currently-supported install path —
this package isn't on `pub.dev` yet):

```yaml
dependencies:
  flutter_graph_db:
    git:
      url: https://github.com/<your-org>/flutter_graph_db.git
      path: flutter_graph_db/packages/flutter_graph_db
```

If you're working on the engine alongside the consuming app, a path
dependency reloads live across the link:

```yaml
dependencies:
  flutter_graph_db:
    path: ../flutter_graph_db/packages/flutter_graph_db
```

## Quick start — in-memory

The shortest path to a working engine. No WAL, no persistence — good
for tests and the read-of-the-week.

```dart
import 'package:flutter_graph_db/flutter_graph_db.dart';

Future<void> main() async {
  // An in-memory WAL store gives a real engine with no on-disk
  // persistence — ideal for tests and scratch work.
  final db = await openWalBackedGraphDb(store: InMemoryWalStore());

  final person = db.internLabel('Person');
  final knows = db.internEdgeType('KNOWS');
  final name = db.internPropKey('name');

  await db.runTransaction((txn) {
    final ada = txn.addNode(labelIds: [person], props: {
      name: const PropString('Ada'),
    });
    final bob = txn.addNode(labelIds: [person], props: {
      name: const PropString('Bob'),
    });
    txn.addEdge(src: ada, dst: bob, typeId: knows);
  });

  // Reads are read-your-writes — the committed nodes show up here with
  // no mergeNow() call. labelScan returns raw int ids; wrap in Vid(..).
  for (final id in db.labelScan(person)) {
    final v = Vid(id);
    print('${db.getNodeStringProp(v, name)} '
          'out=${db.outDegree(v)}');
  }

  // GQL via the extension method `executeQuery` (re-exported from
  // graph_db_gql). Results come back as `result.rows`, each row a
  // `row.values[...]` map keyed by RETURN alias.
  final result = await db.executeQuery(
    'MATCH (n:Person) RETURN n.name AS name',
  );
  for (final row in result.rows) {
    print(row.values['name']);
  }

  await db.close();
}
```

## Read-your-writes — the merge lifecycle

`runTransaction` lands committed mutations in the per-vid **overlay**,
which a background merge later folds into the immutable CSR base. That
merge is a pure compaction detail — **it is never required for
correctness.** A committed mutation is visible to the next read
immediately:

```dart
await db.runTransaction((txn) {
  txn.addNode(labelIds: [person], props: {name: const PropString('Ada')});
});
// No mergeNow() — labelScan, nodeCount, degrees, traversal, property
// reads and executeQuery all already see the new node.
db.labelScan(person); // includes Ada
```

`labelScan`, `forEachOutNeighbor` / `forEachInNeighbor`, `outDegree` /
`inDegree`, `nodeCount` / `edgeCount`, the property accessors,
`hasLabel` / `labelsOf`, and the GQL `MATCH` surface are all
overlay-aware.

**The one exception** is the allocation-free *primitive range* API
(`outRangeStart` / `outRangeEnd` / `outNeighborAt`, and the `in`
equivalents). Those index straight into the CSR arrays, so they reflect
only the last merge — the deliberate price of the zero-allocation
guarantee. `db.hasPendingWrites` tells you when the CSR is stale
relative to committed writes; call `db.state.mergeNow()` to fold the
overlay in (typically <50µs on a small graph) before using that path,
or just use `forEachOutNeighbor`, which is read-your-writes.

Merges otherwise happen automatically once the overlay reaches
`max(10_000, 5% of edges)`.

## Mobile / desktop persistence (iOS / Android / macOS / Windows / Linux)

The native WAL adapter lives in `package:graph_db_wal/io_wal_store.dart`
— a separate import so a web build keeps `dart:io` out of its
dependency cone. Wire it with `path_provider` to land the WAL in the
app's documents directory.

```yaml
dependencies:
  flutter_graph_db:
    git:
      url: https://github.com/<your-org>/flutter_graph_db.git
      path: flutter_graph_db/packages/flutter_graph_db
  graph_db_wal:
    git:
      url: https://github.com/<your-org>/flutter_graph_db.git
      path: flutter_graph_db/packages/graph_db_wal
  path_provider: ^2.1.0
```

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_graph_db/flutter_graph_db.dart';
import 'package:graph_db_wal/io_wal_store.dart'; // native-only adapter
import 'package:path_provider/path_provider.dart';

Future<GraphDb> openMobileDb() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  final store = await IoWalStore.open('${dir.path}/graph.wal');

  // Recovers any prior session's WAL automatically.
  final db = await openWalBackedGraphDb(store: store);
  return db;
}
```

On Android, `getApplicationDocumentsDirectory()` resolves to the app's
sandboxed internal storage — no manifest changes or runtime permission
prompts required. iOS sandboxing is the same; the directory is part of
the app's container.

## Web persistence (Chrome / Safari / Firefox)

The browser-side adapter is opt-in via
`package:graph_db_wal/indexeddb_wal_store.dart`. It uses
`package:web`'s direct JS interop to talk to IndexedDB; no extra
runtime deps.

```dart
import 'package:flutter_graph_db/flutter_graph_db.dart';
import 'package:graph_db_wal/indexeddb_wal_store.dart'; // web-only

Future<GraphDb> openWebDb() async {
  final store = await openIndexedDbWalStore(); // default dbName: 'graph_db_wal'
  final db = await openWalBackedGraphDb(store: store);
  return db;
}
```

A conditional import keeps the right adapter per platform:

```dart
// db_factory.dart
export 'db_factory_io.dart'
  if (dart.library.js_interop) 'db_factory_web.dart';
```

## Snapshot + compact cycle (long-running apps)

> **Gotcha — the WAL does not self-compact yet.** There is no automatic
> checkpoint: every committed mutation appends to the WAL forever until
> *you* run the cycle below. A long-running app that never compacts will
> see the WAL file grow without bound and startup recovery slow down in
> proportion (recovery replays the whole tail). Until auto-checkpoint
> ships, run this cycle periodically — e.g. on a write-count / file-size
> threshold, or at a safe lifecycle point like backgrounding.

Take a snapshot, persist it, and compact the WAL up to the snapshot's
LSN:

```dart
db.state.mergeNow(); // codec invariant: overlay must be empty
final snap = encodeSnapshot(db.state);
await File('${dir.path}/graph.snapshot').writeAsBytes(snap.bytes);
await compactToCurrentTip(store: store);
```

On next launch, restore the snapshot then let recovery replay any WAL
bytes appended after it:

```dart
final snapBytes = await File('${dir.path}/graph.snapshot').readAsBytes();
final db = await openWalBackedGraphDb(
  store: store,
  snapshot: snapBytes,
);
```

The cycle is identical on every platform — only the `WalStore`
implementation differs.

## Sub-packages — when to depend directly

The umbrella re-exports the three packages most apps need (`core`,
`wal`, `gql`). Other packages are opt-in:

| Package | What it adds | When you need it |
|---|---|---|
| [`graph_db_core`](../graph_db_core) | engine only | minimal dependency surface; you're a library author |
| [`graph_db_wal`](../graph_db_wal) | WAL persistence + io / indexeddb adapters | always (transitively via umbrella) |
| [`graph_db_gql`](../graph_db_gql) | OpenCypher subset (parser, planner, push-based executor) | you want `db.executeQuery(...)` |
| [`graph_db_remote`](../graph_db_remote) | `RemoteGraphClient` interface for sync targets | building a custom remote adapter |
| [`graph_db_remote_neo4j`](../graph_db_remote_neo4j) | Bolt v4/v5 client for Neo4j | syncing to Neo4j |
| [`graph_db_remote_falkor`](../graph_db_remote_falkor) | RESP client for FalkorDB | syncing to FalkorDB |
| [`graph_db_sync`](../graph_db_sync) | push-only sync engine | pushing local mutations to a remote graph |
| [`graph_db_bench`](../graph_db_bench) | R-MAT generators + latency harness | local perf testing — see [Benchmarking](#benchmarking) |

## Benchmarking

Two benchmarking surfaces ship in the repo. Pick the one that matches
how you want to measure.

### CLI bench harness — `graph_db_bench`

`packages/graph_db_bench/` — pure-Dart benchmark harness for
non-Flutter measurement runs. R-MAT graph generators, hub-seed
selection, latency + JIT GC-event capture. Mirrors the spike-phase
report format so numbers are directly comparable across runs.

```sh
cd packages/graph_db_bench
dart run bin/read_bench.dart
```

Use this when you want repeatable numbers without Flutter / app
overhead in the loop, or when profiling against a remote backend.

### In-app perf widget

The example app ships a self-contained `PerfBench` widget
(`example/lib/src/widgets/perf_bench.dart`, ~250 lines, depends on
`flutter/material` + `graph_db_core`). Runs N node inserts against a
fresh temp `GraphDb`, then merge, then N×10 reads. Reports total /
p50 / p99 / throughput + merge stall with per-platform tagging +
one-tap clipboard copy.

To use it in your own app: copy the file into your project and drop
`const PerfBench()` anywhere in your widget tree (e.g. a debug page).
Same code path runs on web / iOS / Android / desktop, so cross-target
comparison is paste-and-compare.

## Run the example app

The repo includes a Flutter sample app under `example/` that exercises
the full public API surface — People / Companies / Graph / Stats tabs,
real CRUD, WAL-backed persistence, an interactive node-link graph
view, and the in-app perf bench.

```sh
cd example
flutter pub get
flutter run                              # default device
flutter run -d chrome --profile          # web, profile mode (recommended for perf bench)
flutter run -d <iphone> --release        # iPhone release build
```

See [`example/README.md`](../../example/README.md) for the per-screen
breakdown, persistence + reset behaviour, and the file layout.
