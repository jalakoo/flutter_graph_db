import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// Small directed graph for tests:
///
///   0:Person -knows-> 1:Person
///   0:Person -knows-> 2:Person
///   1:Person -knows-> 2:Person
///   2:Person -worksAt-> 3:Company
Csr _buildFixture() {
  return Csr.fromEdges(
    nodeCount: 4,
    srcs: Uint32List.fromList([0, 0, 1, 2]),
    dsts: Uint32List.fromList([1, 2, 2, 3]),
    edgeTypes: Uint32List.fromList([0, 0, 0, 1]), // 0=knows, 1=worksAt
    labelOf: Uint32List.fromList([0, 0, 0, 1]),   // 0=Person, 1=Company
    labelCount: 2,
  );
}

void main() {
  test('row pointers and column indices are consistent', () {
    final csr = _buildFixture();
    expect(csr.nodeCount, 4);
    expect(csr.edgeCount, 4);
    expect(csr.rowPtrOut[csr.nodeCount], csr.edgeCount);
    expect(csr.rowPtrIn[csr.nodeCount], csr.edgeCount);
  });

  test('out-degrees match the fixture', () {
    final csr = _buildFixture();
    expect(csr.outDegree(0), 2);
    expect(csr.outDegree(1), 1);
    expect(csr.outDegree(2), 1);
    expect(csr.outDegree(3), 0);
  });

  test('in-degrees match the fixture', () {
    final csr = _buildFixture();
    expect(csr.inDegree(0), 0);
    expect(csr.inDegree(1), 1);
    expect(csr.inDegree(2), 2);
    expect(csr.inDegree(3), 1);
  });

  test('forward neighbours of 0 are {1, 2}', () {
    final csr = _buildFixture();
    final start = csr.rowPtrOut[0];
    final end = csr.rowPtrOut[1];
    final neighbors = <int>{};
    for (var i = start; i < end; i++) {
      neighbors.add(csr.colIdxOut[i]);
    }
    expect(neighbors, {1, 2});
  });

  test('reverse neighbours of 2 are {0, 1}', () {
    final csr = _buildFixture();
    final start = csr.rowPtrIn[2];
    final end = csr.rowPtrIn[3];
    final parents = <int>{};
    for (var i = start; i < end; i++) {
      parents.add(csr.colIdxIn[i]);
    }
    expect(parents, {0, 1});
  });

  test('every edge appears in both directions exactly once', () {
    final csr = _buildFixture();
    final fwd = <int>{};
    for (var i = 0; i < csr.edgeCount; i++) {
      fwd.add(csr.edgeIdOut[i]);
    }
    final rev = <int>{};
    for (var i = 0; i < csr.edgeCount; i++) {
      rev.add(csr.edgeIdIn[i]);
    }
    expect(fwd, rev);
    expect(fwd.length, csr.edgeCount);
  });

  test('label index returns the right vids', () {
    final csr = _buildFixture();
    expect(csr.labelIndex[0], orderedEquals([0, 1, 2])); // Person
    expect(csr.labelIndex[1], orderedEquals([3])); // Company
  });

  test('mismatched input lengths raise ArgumentError', () {
    expect(
      () => Csr.fromEdges(
        nodeCount: 2,
        srcs: Uint32List.fromList([0, 1]),
        dsts: Uint32List.fromList([1]),
        edgeTypes: Uint32List.fromList([0, 0]),
        labelOf: Uint32List.fromList([0, 0]),
        labelCount: 1,
      ),
      throwsArgumentError,
    );
  });
}
