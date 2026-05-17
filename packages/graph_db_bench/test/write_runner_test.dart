import 'package:graph_db_bench/graph_db_bench.dart';
import 'package:test/test.dart';

void main() {
  test('runWriteWorkloads(quick: true) returns a structured report',
      () async {
    final r = await runWriteWorkloads(quick: true);
    expect(r.bulkInsertMs, greaterThan(0));
    expect(r.commitStats.samples, 100);
    expect(r.commitStats.p99, greaterThanOrEqualTo(r.commitStats.p50));
    expect(r.mergeStats.samples, 20);
    expect(r.mergeStats.p99, greaterThanOrEqualTo(r.mergeStats.p50));
    final formatted = r.format();
    expect(formatted, contains('bulkAddEdges'));
    expect(formatted, contains('commit latency'));
    expect(formatted, contains('Merge-stall'));
  });
}
