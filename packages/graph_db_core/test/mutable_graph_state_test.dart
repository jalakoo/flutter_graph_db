import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

MutableGraphState _buildState() {
  return MutableGraphState.fromFixture(
    nodeCount: 4,
    srcs: Uint32List.fromList([0, 0, 1, 2]),
    dsts: Uint32List.fromList([1, 2, 2, 3]),
    edgeTypes: Uint32List.fromList([0, 0, 0, 1]),
    labelOf: Uint32List.fromList([0, 0, 0, 1]),
    labelNames: const ['Person', 'Company'],
    edgeTypeNames: const ['knows', 'worksAt'],
  );
}

void main() {
  test('range read API over forward CSR yields the right neighbours', () {
    final s = _buildState();
    final neighbors = <int>{};
    final start = s.outStart(const Vid(0));
    final end = s.outEnd(const Vid(0));
    for (var i = start; i < end; i++) {
      neighbors.add(s.outNeighborAt(i).value);
    }
    expect(neighbors, {1, 2});
  });

  test('reverse range read API yields parents', () {
    final s = _buildState();
    final parents = <int>{};
    final start = s.inStart(const Vid(2));
    final end = s.inEnd(const Vid(2));
    for (var i = start; i < end; i++) {
      parents.add(s.inNeighborAt(i).value);
    }
    expect(parents, {0, 1});
  });

  test('label scan returns vids with that label', () {
    final s = _buildState();
    final personLabel = s.strings.internLabel('Person');
    final companyLabel = s.strings.internLabel('Company');
    expect(s.labelScan(personLabel), orderedEquals([0, 1, 2]));
    expect(s.labelScan(companyLabel), orderedEquals([3]));
    expect(s.labelScan(999), isEmpty);
  });

  test('property reads round-trip through the typed accessors', () {
    final s = _buildState();
    final nameKey = s.strings.internPropKey('name');
    final ageKey = s.strings.internPropKey('age');
    s.nodeProps.setStringId(0, nameKey, 100);
    s.nodeProps.setInt(0, ageKey, 30);
    expect(s.hasNodeProp(const Vid(0), nameKey), true);
    expect(s.getNodeStringIdProp(const Vid(0), nameKey), 100);
    expect(s.getNodeIntProp(const Vid(0), ageKey), 30);
    expect(s.hasNodeProp(const Vid(1), nameKey), false);
  });

  test('edge type ids are recoverable via the string interner', () {
    final s = _buildState();
    final knowsId = s.strings.internEdgeType('knows');
    final start = s.outStart(const Vid(0));
    final end = s.outEnd(const Vid(0));
    var count = 0;
    for (var i = start; i < end; i++) {
      if (s.edgeTypeAt(i) == knowsId) count++;
    }
    expect(count, 2);
  });
}
