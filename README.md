# flutter_graph_db

[![ci](https://github.com/jalakoo/flutter_graph_db/actions/workflows/ci.yaml/badge.svg)](https://github.com/jalakoo/flutter_graph_db/actions/workflows/ci.yaml)

A pure-Dart, Flutter-native embedded graph database. One in-process
engine that runs on iOS, Android, macOS, Windows, Linux, and the
browser (`dart2js` + `dart2wasm`) from the same code path.

## Contents

- [What's in the box](#whats-in-the-box)
- [Getting started](#getting-started)
- [API reference](#api-reference)
- [Run the demo](#run-the-demo)
- [Layout](#layout)
- [Tests](#tests)
- [Performance](#performance)
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

## Getting started

Add the umbrella package — one dependency, one import gives you the
engine + WAL persistence + the GQL query layer. It isn't on `pub.dev`
yet, so use a git (or local path) dependency:

```yaml
dependencies:
  flutter_graph_db:
    git:
      url: https://github.com/jalakoo/flutter_graph_db.git
      path: flutter_graph_db/packages/flutter_graph_db
```

The file below opens a database and runs every basic verb —
**import, initialize, write, read, edit, delete** — against the stable
public API:

```dart
import 'package:flutter_graph_db/flutter_graph_db.dart';

Future<void> main() async {
  // 1 — OPEN. An in-memory store means no persistence (tests / scratch).
  //     Swap it for IoWalStore.open(path) on mobile/desktop or
  //     IndexedDbWalStore on web to persist — nothing else here changes.
  final db = await openWalBackedGraphDb(store: InMemoryWalStore());

  // 2 — INITIALIZE the catalog. Labels, edge types and property keys are
  //     stored as compact int ids. Intern a name once; reuse the id.
  final person = db.internLabel('Person');
  final knows  = db.internEdgeType('KNOWS');
  final name   = db.internPropKey('name');

  // 3 — WRITE. One runTransaction commits atomically and forwards its
  //     return value back to the caller.
  final ada = await db.runTransaction((txn) {
    final a = txn.addNode(labelIds: [person], props: {name: const PropString('Ada')});
    final b = txn.addNode(labelIds: [person], props: {name: const PropString('Bob')});
    txn.addEdge(src: a, dst: b, typeId: knows);
    return a;
  });

  // 4 — READ. Committed writes are visible immediately — reads are
  //     read-your-writes, no mergeNow() required. labelScan returns raw
  //     int ids; wrap each in Vid(..) for the typed read accessors.
  for (final id in db.labelScan(person)) {
    final v = Vid(id);
    print('${db.getNodeStringProp(v, name)}  out=${db.outDegree(v)}');
  }

  // 5 — EDIT. Re-open a transaction; set the property to a new value.
  await db.runTransaction((txn) {
    txn.setNodeProp(ada, name, const PropString('Ada Lovelace'));
  });

  // 6 — DELETE. Tombstones the node and cascades its incident edges
  //     (vids are monotonic and never reused).
  await db.runTransaction((txn) => txn.delNode(ada));

  await db.close();
}
```

Prefer a query language? The same read is one line of the OpenCypher
subset (note: results come back as `result.rows`, each a
`row.values[...]` map):

```dart
final result = await db.executeQuery('MATCH (n:Person) RETURN n.name AS name');
for (final row in result.rows) {
  print(row.values['name']);
}
```

**Persisting on a real device.** Swap the in-memory store for the
platform adapter — your code above is unchanged. The native adapter
ships in a separate import so a web build keeps `dart:io` out of its
dependency cone:

```dart
import 'package:graph_db_wal/io_wal_store.dart';      // native: iOS / Android / desktop
import 'package:path_provider/path_provider.dart';

final dir = await getApplicationDocumentsDirectory();
final store = await IoWalStore.open('${dir.path}/graph.wal');
final db = await openWalBackedGraphDb(store: store);   // recovers the prior session
```

For web persistence, the snapshot + compact cycle, and the conditional
import that picks the right adapter per platform, see the
[umbrella package README](packages/flutter_graph_db/README.md).

## API reference

Two complementary views of the public surface:

- **[API cheatsheet](docs/api-cheatsheet.md)** — the consumer-facing
  methods grouped by task (open · catalog · write · read · query), one
  line each. Start here when you know *what* you want to do.
- **dartdoc** — the exhaustive, always-in-sync reference generated from
  the in-source `///` comments. Generate and browse it locally:

  ```sh
  cd packages/flutter_graph_db
  dart pub get
  dart doc .                       # writes HTML to doc/api/ (gitignored)
  open doc/api/index.html          # or serve: dart pub global activate dhttpd && dhttpd -p doc/api
  ```

  Because you depend on the umbrella, the re-exported symbols from
  `graph_db_core` / `_wal` / `_gql` (`GraphDb`, `PropString`, …) all
  appear in the one `flutter_graph_db` library page — no extra config.

## Run the demo

Tour the full public API in a real app — People / Companies / Graph /
Stats tabs, live CRUD, WAL-backed persistence, an interactive
node-link view, and the in-app perf bench:

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

## Performance

Numbers below are from the in-app perf bench widget
(`example/lib/src/widgets/perf_bench.dart`) running against a fresh
temp `GraphDb`. The bench inserts N nodes, runs a sync overlay
merge, then walks N×10 `outDegree` reads — same code path across
every target.

| Target | N | Inserts / sec | Insert p50 / p99 | Merge stall |
|---|---:|---:|---:|---:|
| Chrome (profile, dart2js, M1 MBP) | 1 000 | 54 645 | 0 / 101 µs | 0.6 ms |
| Chrome (profile, dart2js, M1 MBP) | 10 000 | 63 012 | 0 / 101 µs | 2.4 ms |
| Chrome (profile, dart2js, M1 MBP) | 100 000 | 95 538 | 0 / 100 µs | 13.5 ms |
| iOS (release AOT, iPhone) | 1 000 | 22 048 | 29 / 101 µs | 1.5 ms |
| iOS (release AOT, iPhone) | 10 000 | 114 586 | 2 / 51 µs | 5.6 ms |
| iOS (release AOT, iPhone 16 Pro) | 100 000 | **440 653** | 1 / 7 µs | 2.6 ms |
| Android | — | (pending) | — | — |
| macOS / Linux / Windows | — | (use the bench widget on your dev box) | — | — |

**Headline numbers.** iPhone 16 Pro at N=100 k sustains **440 k
inserts / sec** with a 7 µs p99 — the AOT hot path is fully warmed
and per-op cost falls below the timer floor on the median. Chrome on
an M1 MacBook hits ~96 k inserts / sec at the same scale with a
13.5 ms merge — still under a single 60 Hz frame budget (16.7 ms),
so even with the sync main-isolate fallback the engine doesn't drop
a frame at 100 k nodes.

Reads are sub-µs across all targets (under the timer floor — see
caveats).

### Reading the numbers

- **µs** — microsecond, one millionth of a second (1 µs = 0.001 ms).
  A 60-Hz frame budget is ~16 700 µs; an insert at 100 µs uses 0.6 %
  of one frame.
- **Inserts / sec** — sustained write throughput. Derived from
  `N ÷ total_elapsed_seconds`, so it's robust to per-op timer
  resolution (see Caveats).
- **p50** ("median") — half of all operations finish at or below
  this latency. The typical case.
- **p99** — 99 % of operations finish at or below this latency. The
  tail. Matters for UI smoothness: a p99 of 100 µs means roughly
  1 in 100 inserts pays that cost; at 1 000 inserts/frame that's
  10 dropped-frame candidates per second if the work is on the main
  thread. (Mutations are not on the main thread in production —
  this is why a low p99 matters even though the mean is fine.)
- **p90 / p95 / p99.9** — same idea, different cutoffs.
  The bench reports p50 + p99 because those are the two numbers
  most worth defending against regressions; the others can be
  computed from the latency histogram if you fork the widget.

### Caveats

- **Browser timer resolution.** `performance.now()` is
  Spectre-mitigated to a ~100 µs grain in most browsers, so on web
  the per-op p50 reads as `0 µs` and p99 lands exactly on the grain
  boundary. The **throughput** column is the trustworthy number on
  web — it's derived from total elapsed time, not per-op samples.
- **Native AOT warm-up.** Insert p50 on iOS drops 29 µs → 2 µs → 1 µs
  across N=1 k → 10 k → 100 k as the hot path warms in the AOT
  optimiser; p99 drops 101 µs → 51 µs → 7 µs over the same
  progression. Steady-state per-op cost is well under the timer
  floor.
- **The merge column measures the synchronous main-isolate fold.**
  The bench creates a fresh temp `GraphDb` with no `MergeCoordinator`
  attached, so the worker-isolate hand-off (~30 µs at 100 k edges
  when wired) is bypassed in these numbers. Production apps that
  wire a `MergeCoordinator` get the worker path and don't see this
  cost on the main thread.

### Reproduce

```sh
cd example
flutter run -d chrome --profile     # web
flutter run -d <iphone> --release   # iOS device
flutter run -d <android> --release  # Android device
flutter run -d macos                # macOS native
```

App → bottom-nav **Stats** tab → scroll to the **Perf bench** card →
pick N → tap **Run** → tap the copy icon next to the result line.
The output is platform-tagged so cross-target comparison is
paste-and-compare.

For repeatable CLI numbers (no Flutter / app overhead), the
[`graph_db_bench`](packages/graph_db_bench) package ships a desktop
runner:

```sh
cd packages/graph_db_bench
dart run bin/read_bench.dart           # JIT
dart compile exe bin/read_bench.dart -o build/bench && ./build/bench   # AOT
```

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
  Web targets fall back to a synchronous main-isolate fold. **Reads are
  read-your-writes:** `labelScan`, traversal (`forEachOut/InNeighbor`),
  `nodeCount` / `edgeCount` / degrees, property reads, and the GQL
  `MATCH` surface all consult the overlay, so a committed mutation is
  visible immediately — merge is a pure background-compaction detail,
  never a correctness step. The allocation-free primitive range API is
  the one snapshot-of-last-merge exception; `db.hasPendingWrites` reports
  when it is stale.
- **WAL persistence** — CBOR + length-prefix framing + xxHash64
  checksum per record. Recovery is two-pass redo-with-commit. Three
  adapters in tree: in-memory, native file (`dart:io`), and IndexedDB.
- **GQL surface** — OpenCypher read-subset via a Dart extension on
  `GraphDb`; planner emits a push-based operator tree with an LRU
  plan cache.
- **Sync engine** — push-only WAL drain → bulk import to remote
  targets; per-target HWM + quarantine queue; `fullExport` seeding
  mode for new targets.
