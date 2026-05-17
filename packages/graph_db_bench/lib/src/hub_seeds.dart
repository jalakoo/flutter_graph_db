import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

/// The [count] vids with the highest out-degree in [csr], highest first.
///
/// Used to seed traversal benchmarks. In a sparse graph (avg out-degree
/// ~1) random seeds mostly hit degree-0/1 nodes, so the traversal inner
/// loop barely runs and the benchmark measures per-call overhead instead
/// of per-element cost. Hub seeds make the inner loop actually run deep
///.
Uint32List topOutDegreeVids(Csr csr, int count) {
  final vids = Uint32List(csr.nodeCount);
  for (var v = 0; v < csr.nodeCount; v++) {
    vids[v] = v;
  }
  vids.sort((a, b) => csr.outDegree(b).compareTo(csr.outDegree(a)));
  final n = count < csr.nodeCount ? count : csr.nodeCount;
  return vids.sublist(0, n);
}
