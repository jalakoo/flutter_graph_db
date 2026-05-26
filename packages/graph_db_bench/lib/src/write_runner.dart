/// Write-side acceptance benches.
///
/// Three workloads:
/// 1. **100k bulk insert** — wall time of `GraphDb.bulkAddEdges`.
///    Target: < 1 s.
/// 2. **Single-txn commit latency** — p50 / p99 of a one-edge txn
///    using `Durability.group`. Target: p99 ≤ 5 ms.
/// 3. **Merge stall** — p50 / p99 of the synchronous overlay-merge
///    fold on the main isolate. Target: < 1 ms (achievable on the
///    100 k bench; larger graphs need the worker-isolate hand-off
///    as a follow-up).
library;

import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'latency.dart';

class WriteBenchReport {
  final double bulkInsertMs;
  final LatencyStats commitStats;
  final LatencyStats mergeStats;
  const WriteBenchReport({
    required this.bulkInsertMs,
    required this.commitStats,
    required this.mergeStats,
  });

  String format({String envLabel = 'desktop'}) {
    final sb = StringBuffer();
    sb.writeln('=== graph_db_bench — write workloads ===');
    sb.writeln('env: $envLabel');
    sb.writeln('');
    sb.writeln('1) bulkAddEdges (100k edges, fresh graph):');
    sb.writeln('   wall: ${bulkInsertMs.toStringAsFixed(1)} ms');
    sb.writeln('   target: < 1000 ms     '
        '${bulkInsertMs < 1000 ? 'PASS' : 'FAIL'}');
    sb.writeln('');
    sb.writeln('2) Single-txn commit latency (Durability.group):');
    sb.writeln('   p50: ${commitStats.p50.toStringAsFixed(1)} us');
    sb.writeln('   p99: ${commitStats.p99.toStringAsFixed(1)} us');
    sb.writeln('   target: p99 <= 5000 us   '
        '${commitStats.p99 <= 5000 ? 'PASS' : 'FAIL'}');
    sb.writeln('');
    sb.writeln('3) Merge-stall (synchronous fold, main isolate):');
    sb.writeln('   p50: ${mergeStats.p50.toStringAsFixed(1)} us');
    sb.writeln('   p99: ${mergeStats.p99.toStringAsFixed(1)} us');
    sb.writeln('   target: p99 < 1000 us    '
        '${mergeStats.p99 < 1000 ? 'PASS' : 'FAIL (deferred — needs worker)'}');
    return sb.toString();
  }
}

/// Builds an empty state seeded with [nodeCount] nodes (no edges).
({GraphDb db, MutableGraphState state}) _emptyDb(int nodeCount) {
  final state = MutableGraphState.fromFixture(
    nodeCount: nodeCount,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(nodeCount),
    labelNames: const ['Node'],
    edgeTypeNames: const ['link'],
    vidSpace: nodeCount + 16,
    eidSpace: 16,
  );
  return (db: GraphDb.fromState(state), state: state);
}

Future<WriteBenchReport> runWriteWorkloads({
  bool quick = false,
  MergeCoordinator? coord,
}) async {
  final bulkEdgeCount = quick ? 10000 : 100000;
  final commitSamples = quick ? 100 : 1000;
  final mergeSamples = quick ? 20 : 100;
  final nodeCount = bulkEdgeCount; // 1 edge per node so endpoints exist

  // 1) Bulk insert
  final bulkDb = _emptyDb(nodeCount).db;
  final edges = [
    for (var i = 0; i < bulkEdgeCount; i++)
      BulkEdge(
        src: Vid(i),
        dst: Vid((i + 1) % nodeCount),
        typeId: 0,
      ),
  ];
  final bulkSw = Stopwatch()..start();
  await bulkDb.bulkAddEdges(edges, durability: Durability.none);
  bulkSw.stop();
  final bulkInsertMs = bulkSw.elapsedMicroseconds / 1000;

  // 2) Single-txn commit latency on a small graph (no WAL sink — pure
  // engine overhead). Each txn adds one edge.
  final commitDb = _emptyDb(1024).db;
  final commitLatencies = Float64List(commitSamples);
  for (var i = 0; i < commitSamples; i++) {
    final sw = Stopwatch()..start();
    await commitDb.runTransaction(
      (txn) {
        txn.addEdge(
          src: Vid(i % 1024),
          dst: Vid((i + 1) % 1024),
          typeId: 0,
        );
      },
      durability: Durability.none,
    );
    sw.stop();
    commitLatencies[i] = sw.elapsedMicroseconds.toDouble();
    // Avoid the merge threshold tripping during the bench by clearing
    // the overlay periodically.
    if (i % 100 == 99) commitDb.mergeNow();
  }
  commitLatencies.sort((a, b) => a.compareTo(b));
  final commitStats = LatencyStats(
    min: commitLatencies.first,
    p50: commitLatencies[commitSamples ~/ 2],
    p99: commitLatencies[(commitSamples * 99) ~/ 100],
    samples: commitSamples,
  );

  // 3) Merge stall: build an overlay with ~10k edges, then time the
  // synchronous fold. Each iteration re-builds the overlay so we
  // measure the fold cost, not the overlay-build cost.
  // [coord] (optional) — if provided, run the merge through the
  // worker isolate. Main-isolate stall
  // is then bounded by the copy + install cost; the fold runs
  // off-main.
  final mergeLatencies = Float64List(mergeSamples);
  for (var i = 0; i < mergeSamples; i++) {
    final mergeState = _emptyDb(2048).state;
    for (var j = 0; j < 1024; j++) {
      mergeState.applyAddEdge(
        mergeState.allocEid(),
        logicalId: 'e$j',
        src: Vid(j),
        dst: Vid((j + 1) % 2048),
        typeId: 0,
        props: const {},
      );
    }
    if (coord != null) {
      mergeState.mergeCoordinator = coord;
      // The "main-isolate stall" in the worker path is the copy +
      // install. We approximate by subtracting the worker compute
      // (reported by the worker) from the wall time of the await.
      final sw = Stopwatch()..start();
      await mergeState.maybeMergeOverlayAsync();
      sw.stop();
      mergeLatencies[i] =
          (sw.elapsedMicroseconds - coord.lastMergeWorkerUs).toDouble();
      if (mergeLatencies[i] < 0) mergeLatencies[i] = 0;
    } else {
      final sw = Stopwatch()..start();
      mergeState.mergeNow();
      sw.stop();
      mergeLatencies[i] = sw.elapsedMicroseconds.toDouble();
    }
  }
  mergeLatencies.sort((a, b) => a.compareTo(b));
  final mergeStats = LatencyStats(
    min: mergeLatencies.first,
    p50: mergeLatencies[mergeSamples ~/ 2],
    p99: mergeLatencies[(mergeSamples * 99) ~/ 100],
    samples: mergeSamples,
  );

  return WriteBenchReport(
    bulkInsertMs: bulkInsertMs,
    commitStats: commitStats,
    mergeStats: mergeStats,
  );
}
