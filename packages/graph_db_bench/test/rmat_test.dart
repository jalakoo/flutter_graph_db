import 'package:graph_db_bench/graph_db_bench.dart';
import 'package:test/test.dart';

void main() {
  test('R-MAT produces a CSR with the expected node/edge counts', () {
    final r = rmat(nodeCount: 1 << 12, edgeCount: 5000, labelCount: 8);
    expect(r.srcs.length, 5000);
    expect(r.dsts.length, 5000);
    expect(r.labelOf.length, 1 << 12);

    final state = buildFixture(r);
    expect(state.csr.nodeCount, 1 << 12);
    expect(state.csr.edgeCount, 5000);
    expect(state.csr.rowPtrOut.last, 5000);
    expect(state.csr.rowPtrIn.last, 5000);
  });

  test('topOutDegreeVids returns vids in descending out-degree', () {
    final r = rmat(nodeCount: 1 << 12, edgeCount: 5000, labelCount: 8);
    final state = buildFixture(r);
    final hubs = topOutDegreeVids(state.csr, 32);
    expect(hubs.length, 32);
    var prev = 1 << 62;
    for (final v in hubs) {
      final deg = state.csr.outDegree(v);
      expect(deg, lessThanOrEqualTo(prev), reason: 'not descending at vid=$v');
      prev = deg;
    }
    expect(state.csr.outDegree(hubs.first), greaterThan(0));
  });

  test('runReadWorkloads produces a non-empty report with every section',
      () async {
    final report = await runReadWorkloads(
      quick: true,
      conn: SelfConnection(null, null), // latency-only — fast in unit tests
      envLabel: 'unit-test',
    );
    expect(report, contains('out-neighbour traversal'));
    expect(report, contains('label scan'));
    expect(report, contains('2-hop BFS'));
    expect(report, contains('property predicate scan'));
    // Every shape row should be present somewhere.
    expect(report, contains('primitive'));
    expect(report, contains('iterable'));
    expect(report, contains('callback'));
  }, timeout: const Timeout(Duration(seconds: 90)));
}
