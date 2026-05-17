import 'package:graph_db_bench/graph_db_bench.dart';
import 'package:test/test.dart';

void main() {
  test('runIndexWorkloads(quick: true) returns a structured report',
      () async {
    final r = await runIndexWorkloads(quick: true);
    expect(r.nodeCount, 10000);
    expect(r.iterations, 100);
    expect(r.syncUpdateStats.p99, greaterThanOrEqualTo(r.syncUpdateStats.p50));
    expect(
      r.deferredUpdateStats.p99,
      greaterThanOrEqualTo(r.deferredUpdateStats.p50),
    );
    expect(r.deferredFlushMs, greaterThan(0));
    // Deferred p50 should be substantially cheaper than sync p50 —
    // the cost is shifted to the flush.
    expect(r.deferredUpdateStats.p50, lessThan(r.syncUpdateStats.p50));
    final report = r.format();
    expect(report, contains('Sync'));
    expect(report, contains('Deferred'));
  });
}
