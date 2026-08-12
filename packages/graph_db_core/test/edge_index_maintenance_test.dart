import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// Edge-property indexes must track edge mutations.
///
/// Regression: `IndexRegistry` had `beforeNodeWrite` / `afterNodeWrite` /
/// `onNodeDeleted` and no edge counterparts. `createEdgePropertyIndex`
/// registered an index and nothing ever maintained it, so after
/// `setEdgeProp` the index still answered with the old value and a
/// lookup for the new value found nothing.

class _Fixture {
  final GraphDb db;
  final int weight;
  final int knows;
  final Vid a;
  final Vid b;
  _Fixture(this.db, this.weight, this.knows, this.a, this.b);

  static Future<_Fixture> create() async {
    final db = GraphDb.fromState(MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const ['P'],
      edgeTypeNames: const ['KNOWS'],
      vidSpace: 16,
      eidSpace: 16,
    ));
    final p = db.internLabel('P');
    final knows = db.internEdgeType('KNOWS');
    final weight = db.internPropKey('weight');
    final a = await db.runTransaction((t) => t.addNode(labelIds: [p]));
    final b = await db.runTransaction((t) => t.addNode(labelIds: [p]));
    return _Fixture(db, weight, knows, a, b);
  }
}

/// Ids the index reports for [value], via the sorted arrays.
List<int> _lookup(SecondaryIndex idx, int value) {
  final i = idx as IntEqualityRangeIndex;
  return [
    for (var k = i.lowerBound(value); k < i.upperBound(value); k++) i.vidAt(k),
  ];
}

void main() {
  test('edge index follows setEdgeProp', () async {
    final f = await _Fixture.create();
    final e = await f.db.runTransaction((t) => t.addEdge(
        src: f.a, dst: f.b, typeId: f.knows, props: {f.weight: const PropInt(1)}));
    f.db.createEdgePropertyIndex(
        IndexSpec(name: 'w', keyId: f.weight, kind: const EqualityRange()));
    expect(_lookup(f.db.getEdgeIndex('w')!, 1), [e.value]);

    await f.db
        .runTransaction((t) => t.setEdgeProp(e, f.weight, const PropInt(99)));

    final idx = f.db.getEdgeIndex('w')!;
    expect(f.db.getEdgeIntProp(e, f.weight), 99);
    expect(_lookup(idx, 99), [e.value], reason: 'new value must be indexed');
    expect(_lookup(idx, 1), isEmpty, reason: 'old value must be gone');
  });

  test('edge index picks up an edge created after the index', () async {
    final f = await _Fixture.create();
    f.db.createEdgePropertyIndex(IndexSpec(
      name: 'w',
      keyId: f.weight,
      kind: const EqualityRange(),
      valueType: ColumnType.int_,
    ));
    final e = await f.db.runTransaction((t) => t.addEdge(
        src: f.a, dst: f.b, typeId: f.knows, props: {f.weight: const PropInt(7)}));
    expect(_lookup(f.db.getEdgeIndex('w')!, 7), [e.value]);
  });

  test('edge index drops the entry on delEdge', () async {
    final f = await _Fixture.create();
    final e = await f.db.runTransaction((t) => t.addEdge(
        src: f.a, dst: f.b, typeId: f.knows, props: {f.weight: const PropInt(5)}));
    f.db.createEdgePropertyIndex(
        IndexSpec(name: 'w', keyId: f.weight, kind: const EqualityRange()));
    expect(f.db.getEdgeIndex('w')!.length, 1);

    await f.db.runTransaction((t) => t.delEdge(e));

    expect(f.db.getEdgeIndex('w')!.length, 0);
    expect(_lookup(f.db.getEdgeIndex('w')!, 5), isEmpty);
    expect(f.db.hasEdgeProp(e, f.weight), isFalse,
        reason: 'a deleted edge keeps no property values');
  });

  test('edge index drops entries when the incident node is deleted', () async {
    final f = await _Fixture.create();
    await f.db.runTransaction((t) => t.addEdge(
        src: f.a, dst: f.b, typeId: f.knows, props: {f.weight: const PropInt(3)}));
    f.db.createEdgePropertyIndex(
        IndexSpec(name: 'w', keyId: f.weight, kind: const EqualityRange()));
    expect(f.db.getEdgeIndex('w')!.length, 1);

    await f.db.runTransaction((t) => t.delNode(f.b));

    expect(f.db.getEdgeIndex('w')!.length, 0);
  });

  test('edge index drops the entry on delEdgeProp', () async {
    final f = await _Fixture.create();
    final e = await f.db.runTransaction((t) => t.addEdge(
        src: f.a, dst: f.b, typeId: f.knows, props: {f.weight: const PropInt(4)}));
    f.db.createEdgePropertyIndex(
        IndexSpec(name: 'w', keyId: f.weight, kind: const EqualityRange()));
    await f.db.runTransaction((t) => t.delEdgeProp(e, f.weight));
    expect(f.db.getEdgeIndex('w')!.length, 0);
  });

  test('a unique edge index rejects a duplicate value', () async {
    final f = await _Fixture.create();
    await f.db.runTransaction((t) => t.addEdge(
        src: f.a, dst: f.b, typeId: f.knows, props: {f.weight: const PropInt(1)}));
    f.db.createEdgePropertyIndex(IndexSpec(
      name: 'uq_w',
      keyId: f.weight,
      kind: const EqualityRange(unique: true),
    ));
    await expectLater(
      f.db.runTransaction((t) => t.addEdge(
          src: f.b,
          dst: f.a,
          typeId: f.knows,
          props: {f.weight: const PropInt(1)})),
      throwsA(isA<ConstraintViolation>()),
    );
  });

  test('unique + incremental is rejected rather than silently downgraded',
      () async {
    final f = await _Fixture.create();
    expect(
      () => f.db.createEdgePropertyIndex(IndexSpec(
        name: 'bad',
        keyId: f.weight,
        kind: const EqualityRange(unique: true, incremental: true),
        valueType: ColumnType.int_,
      )),
      throwsA(isA<ConstraintViolation>()),
    );
  });
}
