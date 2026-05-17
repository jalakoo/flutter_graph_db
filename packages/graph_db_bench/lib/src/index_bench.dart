/// Indexed-update acceptance bench.
///
/// Builds an indexed property over a [nodeCount]-node graph, then
/// measures the wall-clock latency of [iterations] property updates
/// against that indexed column. Target: `p99 ≤ 100 µs` at
/// 1 M nodes.
///
/// **Honest expectation:** the baseline strategy is drop-and-rebuild
/// — O(n) per mutation. At 1 M nodes that's milliseconds
/// per update, not microseconds. The bench is wired to make the gap
/// visible and motivate the worker-isolate offload + the
/// incremental insert/delete refinement needed to actually hit the
/// target.
library;

import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'latency.dart';

class IndexBenchReport {
  final int nodeCount;
  final int iterations;
  final LatencyStats syncUpdateStats;
  final LatencyStats deferredUpdateStats;
  final double deferredFlushMs;
  final LatencyStats incrementalUpdateStats;
  const IndexBenchReport({
    required this.nodeCount,
    required this.iterations,
    required this.syncUpdateStats,
    required this.deferredUpdateStats,
    required this.deferredFlushMs,
    required this.incrementalUpdateStats,
  });

  String format({String envLabel = 'desktop'}) {
    final sb = StringBuffer();
    sb.writeln('=== graph_db_bench — indexed-update workloads ===');
    sb.writeln('env: $envLabel');
    sb.writeln('fixture: $nodeCount nodes, $iterations updates per shape');
    sb.writeln('');
    sb.writeln('1) Sync (non-deferred) index — every mutation rebuilds inline:');
    sb.writeln('   p50: ${syncUpdateStats.p50.toStringAsFixed(1)} us');
    sb.writeln('   p99: ${syncUpdateStats.p99.toStringAsFixed(1)} us');
    sb.writeln('   target: p99 <= 100 us  '
        '${syncUpdateStats.p99 <= 100 ? 'PASS' : 'FAIL (expected — drop-and-rebuild is O(n); incremental indexes close the gap)'}');
    sb.writeln('');
    sb.writeln('2) Deferred index — mutation queues only, flush at the end:');
    sb.writeln('   per-update p50: '
        '${deferredUpdateStats.p50.toStringAsFixed(1)} us');
    sb.writeln('   per-update p99: '
        '${deferredUpdateStats.p99.toStringAsFixed(1)} us');
    sb.writeln('   flush (one-shot)  : '
        '${deferredFlushMs.toStringAsFixed(1)} ms');
    sb.writeln(
        '   target on the per-update p99: <= 100 us  '
        '${deferredUpdateStats.p99 <= 100 ? 'PASS' : 'FAIL'}');
    sb.writeln('');
    sb.writeln(
        '3) Incremental index (EqualityRange(incremental: true), int_) — '
        'O(1) hash insert, lazy sort:');
    sb.writeln('   p50: '
        '${incrementalUpdateStats.p50.toStringAsFixed(1)} us');
    sb.writeln('   p99: '
        '${incrementalUpdateStats.p99.toStringAsFixed(1)} us');
    sb.writeln(
        '   target: p99 <= 100 us  '
        '${incrementalUpdateStats.p99 <= 100 ? 'PASS' : 'FAIL'}');
    return sb.toString();
  }
}

Future<IndexBenchReport> runIndexWorkloads({bool quick = false}) async {
  final nodeCount = quick ? 10000 : 1000000;
  final iterations = quick ? 100 : 1000;

  // Seed nodeCount nodes + an int 'score' property + a Person label.
  final labelOf = Uint32List(nodeCount);
  final state = MutableGraphState.fromFixture(
    nodeCount: nodeCount,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: labelOf,
    labelNames: const ['Person'],
    edgeTypeNames: const [],
    vidSpace: nodeCount + 16,
    eidSpace: 16,
  );
  final db = GraphDb.fromState(state);
  final score = db.internPropKey('score');
  for (var i = 0; i < nodeCount; i++) {
    state.nodeProps.setInt(i, score, i);
  }

  // ----- 1) Sync index — every mutation triggers a rebuild.
  db.createNodePropertyIndex(IndexSpec(
    name: 'score_sync',
    keyId: score,
    kind: const EqualityRange(),
  ));
  final syncLat = Float64List(iterations);
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    state.applySetNodeProp(
      Vid(i % nodeCount),
      score,
      PropInt(1000000 + i),
    );
    sw.stop();
    syncLat[i] = sw.elapsedMicroseconds.toDouble();
  }
  syncLat.sort((a, b) => a.compareTo(b));
  final syncStats = LatencyStats(
    min: syncLat.first,
    p50: syncLat[iterations ~/ 2],
    p99: syncLat[(iterations * 99) ~/ 100],
    samples: iterations,
  );

  // Drop the sync index so the deferred bench starts clean.
  db.dropNodeIndex('score_sync');

  // ----- 2) Deferred index — mutations queue, single flush at the end.
  db.createNodePropertyIndex(IndexSpec(
    name: 'score_def',
    keyId: score,
    kind: const EqualityRange(deferred: true),
  ));
  final defLat = Float64List(iterations);
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    state.applySetNodeProp(
      Vid(i % nodeCount),
      score,
      PropInt(2000000 + i),
    );
    sw.stop();
    defLat[i] = sw.elapsedMicroseconds.toDouble();
  }
  defLat.sort((a, b) => a.compareTo(b));
  final defStats = LatencyStats(
    min: defLat.first,
    p50: defLat[iterations ~/ 2],
    p99: defLat[(iterations * 99) ~/ 100],
    samples: iterations,
  );
  final flushSw = Stopwatch()..start();
  state.flushDeferredIndexUpdates();
  flushSw.stop();

  // Drop the deferred index so the incremental bench starts clean.
  db.dropNodeIndex('score_def');

  // ----- 3) Incremental index — O(1) hash insert + lazy resort.
  db.createNodePropertyIndex(IndexSpec(
    name: 'score_inc',
    keyId: score,
    kind: const EqualityRange(incremental: true),
  ));
  // Warmup — JIT + first allocations don't pollute the percentile tail.
  final warmup = (iterations >> 2).clamp(32, iterations);
  for (var i = 0; i < warmup; i++) {
    state.applySetNodeProp(
      Vid(i % nodeCount),
      score,
      PropInt(4000000 + i),
    );
  }
  final incLat = Float64List(iterations);
  for (var i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    state.applySetNodeProp(
      Vid(i % nodeCount),
      score,
      PropInt(3000000 + i),
    );
    sw.stop();
    incLat[i] = sw.elapsedMicroseconds.toDouble();
  }
  incLat.sort((a, b) => a.compareTo(b));
  final incStats = LatencyStats(
    min: incLat.first,
    p50: incLat[iterations ~/ 2],
    p99: incLat[(iterations * 99) ~/ 100],
    samples: iterations,
  );

  return IndexBenchReport(
    nodeCount: nodeCount,
    iterations: iterations,
    syncUpdateStats: syncStats,
    deferredUpdateStats: defStats,
    deferredFlushMs: flushSw.elapsedMicroseconds / 1000,
    incrementalUpdateStats: incStats,
  );
}
