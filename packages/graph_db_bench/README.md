# graph_db_bench

Dev-only benchmark harness for `graph_db_core` — plan §12. Owns the
R-MAT fixture generator, hub-seed traversal selection, latency
percentiles, JIT GC-event signal, and the Phase-1 read workloads from
plan §15.

Mirrors `SPIKE_A/` in shape so numbers are directly comparable to the
spike record. The difference is that `graph_db_bench` benches the real
`graph_db_core` API (`MutableGraphState` + `GraphDb`), not a standalone
SPIKE_A clone.

## Workloads

- **Out-neighbour traversal** — folds over hub seeds in three shapes:
  `iterable` (sync\* — not offered by `graph_db_core`, benched only for
  comparison), `callback` (`GraphDb.forEachOutNeighbor` sugar),
  `primitive` (direct CSR range indexing — the locked Phase-1 read API).
- **Label scan** — `for-in` vs indexed loop over the pre-built sorted
  vid list. Plan §15 acceptance: p50 ≤ 10µs / 1k vids.
- **2-hop BFS** — reused-scratch BFS with epoch-marker visited set.
  Plan §15 acceptance: p50 ≤ 100µs over a 100k-edge graph.
- **Property predicate scan** — raw typed accessor
  (`GraphDb.getNodeIntProp`) vs the boundary boxed accessor
  (`GraphDb.getNodeProp` → `PropInt`). Plan §15 acceptance: p50 ≤ 5ms /
  1M nodes.

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

- **`gc/op`** — mean GCs triggered per op. JIT-only. At the noise floor
  (~0.000) ⇒ the inner loop is allocation-free; clearly non-zero ⇒ it
  allocates.
- **`p50` / `p99` / `min`** — latency percentiles in µs. Label scan, BFS,
  and property scan carry the plan §15 targets; PASS / FAIL is printed
  per row.

## On-device verdict (recommended follow-up)

The numbers that drive a perf-claim live on physical hardware. Mirror
the `SPIKE_A/device_runner/` pattern: a thin Flutter app that calls
`runReadWorkloads(...)` from an `integration_test`, prints the report
to the host console. Pattern:

```
packages/graph_db_bench/device_runner/
  pubspec.yaml             # flutter + integration_test + path: ../
  lib/main.dart            # one-screen "Run" app
  integration_test/bench_test.dart
```

Run:
`flutter test integration_test/bench_test.dart -d <iphone-id>`

Out of scope for this commit; add when an iPhone perf-regression check
is needed.

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
bin/
  read_bench.dart        # desktop CLI
test/
  rmat_test.dart         # smoke: fixture + runner
```
