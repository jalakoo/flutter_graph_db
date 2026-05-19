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

  // ----- Multi-label rollout PR 1 -----
  //
  // Ragged-CSR storage is built alongside the legacy single-label
  // `labelOf` (each row length 1 under the v1 invariant). PR 2 lifts
  // the invariant and rewires the build loop; these tests pin the
  // shape so PR 2's broader fold change is visible.

  test('PR 1: ragged labelRowPtr/labels mirror single-label labelOf', () {
    final csr = _buildFixture();
    expect(csr.labelRowPtr.length, csr.nodeCount + 1);
    expect(csr.labels.length, csr.nodeCount);
    for (var v = 0; v < csr.nodeCount; v++) {
      expect(csr.labelCountOf(v), 1, reason: 'single-label invariant');
      expect(csr.labelsOf(v).single, csr.labelOf[v]);
    }
  });

  test('PR 1: hasLabel matches labelOf for every vid', () {
    final csr = _buildFixture();
    for (var v = 0; v < csr.nodeCount; v++) {
      expect(csr.hasLabel(v, csr.labelOf[v]), isTrue);
      expect(csr.hasLabel(v, csr.labelOf[v] + 100), isFalse,
          reason: 'unseen label id returns false');
    }
  });

  test('PR 1: labelsOf returns a zero-copy Uint32List view', () {
    final csr = _buildFixture();
    final view = csr.labelsOf(0);
    expect(view, isA<Uint32List>());
    expect(view.length, 1);
    expect(view[0], 0);
  });

  // ----- Multi-label rollout PR 2 (ragged-CSR build) -----

  test('PR 2: ragged input builds multi-bucket label index', () {
    final labelRowPtr = Uint32List.fromList([0, 2, 3, 4]);
    final labels = Uint32List.fromList([0, 1, 0, 2]);
    final labelOf = Uint32List.fromList([0, 0, 2]);
    final csr = Csr.fromEdges(
      nodeCount: 3,
      srcs: Uint32List.fromList([0]),
      dsts: Uint32List.fromList([1]),
      edgeTypes: Uint32List.fromList([0]),
      labelOf: labelOf,
      labelRowPtr: labelRowPtr,
      labels: labels,
      labelCount: 3,
    );
    expect(csr.labelIndex[0], orderedEquals([0, 1]));
    expect(csr.labelIndex[1], orderedEquals([0]));
    expect(csr.labelIndex[2], orderedEquals([2]));
    expect(csr.hasLabel(0, 0), isTrue);
    expect(csr.hasLabel(0, 1), isTrue);
    expect(csr.hasLabel(0, 2), isFalse);
    expect(csr.labelCountOf(0), 2);
    expect(csr.labelCountOf(1), 1);
  });

  test('PR 2: hasLabel uses binary search across edge positions', () {
    final csr = Csr.fromEdges(
      nodeCount: 1,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List.fromList([1]),
      labelRowPtr: Uint32List.fromList([0, 5]),
      labels: Uint32List.fromList([1, 3, 5, 7, 9]),
      labelCount: 10,
    );
    expect(csr.hasLabel(0, 1), isTrue);
    expect(csr.hasLabel(0, 5), isTrue);
    expect(csr.hasLabel(0, 9), isTrue);
    expect(csr.hasLabel(0, 0), isFalse);
    expect(csr.hasLabel(0, 4), isFalse);
    expect(csr.hasLabel(0, 10), isFalse);
  });

  test('PR 2: tombstoned vid excluded from every label bucket', () {
    final csr = Csr.fromEdges(
      nodeCount: 2,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List.fromList([0, 0]),
      labelRowPtr: Uint32List.fromList([0, 2, 4]),
      labels: Uint32List.fromList([0, 1, 0, 1]),
      labelCount: 2,
      nodeTombstones: Uint8List.fromList([0, 1]),
    );
    expect(csr.labelIndex[0], orderedEquals([0]));
    expect(csr.labelIndex[1], orderedEquals([0]));
  });
}
