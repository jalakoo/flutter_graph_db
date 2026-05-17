# graph_db_bench

Dev-only benchmark harness for `graph_db_core`. R-MAT fixture
generator, hub-seed selection, latency percentiles, JIT GC-event
signal, and read / write workloads against the real engine API.

For an in-app perf measurement widget that runs on iOS / Android /
web / desktop from inside a Flutter app, see the `PerfBench` widget
shipped in [`example/lib/src/widgets/perf_bench.dart`](../../example/lib/src/widgets/perf_bench.dart).
Use the bench package here when you want repeatable CLI numbers
without Flutter / app overhead in the loop.

## Contents

- [Workloads](#workloads)
- [Running](#running)
- [Reading the output](#reading-the-output)
- [On-device runs](#on-device-runs)
- [Layout](#layout)

## Workloads

- **Out-neighbour traversal** — folds over hub seeds in three shapes:
  `iterable` (for comparison only — `graph_db_core` doesn't actually
  expose this shape), `callback` (`GraphDb.forEachOutNeighbor`
  sugar), and `primitive` (direct CSR range indexing — the locked
  fast-path read API).
- **Label scan** — `for-in` vs indexed loop over the pre-built sorted
  vid list. Target: p50 ≤ 10 µs / 1k vids.
- **2-hop BFS** — reused-scratch BFS with epoch-marker visited set.
  Target: p50 ≤ 100 µs over a 100k-edge graph.
- **Property predicate scan** — raw typed accessor
  (`GraphDb.getNodeIntProp`) vs the boundary boxed accessor
  (`GraphDb.getNodeProp` → `PropInt`). Target: p50 ≤ 5 ms / 1M nodes.

## Running

Desktop — JIT (with GC signal):

```sh
dart pub get
dart test
dart run --enable-vm-service bin/read_bench.dart           # full fixtures
dart run --enable-vm-service bin/read_bench.dart --quick   # smaller, faster
```

Desktop — AOT (closer to device; no GC signal):

```sh
dart compile exe bin/read_bench.dart -o build/bench
./build/bench
./build/bench --quick
```

## Reading the output

- **`gc/op`** — mean GCs triggered per op. JIT-only. At the noise
  floor (~0.000) ⇒ the inner loop is allocation-free; clearly
  non-zero ⇒ it allocates.
- **`p50` / `p99` / `min`** — latency percentiles in µs. Label scan,
  BFS, and property scan carry per-workload targets; PASS / FAIL is
  printed per row.

## On-device runs

The numbers that drive a real perf claim live on physical hardware.
A thin Flutter app can call `runReadWorkloads(...)` from an
`integration_test` and print the report to the host console:

```
packages/graph_db_bench/device_runner/
  pubspec.yaml             # flutter + integration_test + path: ../
  lib/main.dart            # one-screen "Run" app
  integration_test/bench_test.dart
```

Run:
`flutter test integration_test/bench_test.dart -d <iphone-id>`

Out of scope for this package's default ship — add when an
iPhone / Android perf-regression check is needed.

## Layout

```
lib/
  graph_db_bench.dart    # public exports
  src/
    rmat.dart            # R-MAT generator + buildFixture
    hub_seeds.dart       # topOutDegreeVids
    latency.dart         # LatencyStats + measureLatency + blackhole + escapeSink
    gc_signal.dart       # SelfConnection + connectSelf + measureGcPerOp
    runner.dart          # runReadWorkloads — full report string
    write_runner.dart    # write-side workloads
    index_bench.dart     # secondary-index build + query bench
bin/
  read_bench.dart        # desktop CLI
test/
  rmat_test.dart         # smoke: fixture + runner
```
