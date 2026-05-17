import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

GraphDb _db({int n = 100}) {
  final state = MutableGraphState.fromFixture(
    nodeCount: n,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(n),
    labelNames: const ['Node'],
    edgeTypeNames: const [],
    vidSpace: n + 16,
    eidSpace: 16,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('5+: incremental insert/removeVid on IntEqualityRangeIndex', () {
    test('build of an incremental index populates the hash + vidToValue maps',
        () {
      final db = _db(n: 5);
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(incremental: true),
      )) as IntEqualityRangeIndex;
      // Range queries work.
      expect(idx.length, 5);
      expect(idx.lowerBound(12), 2);
      // Hash overlay equality lookup works without an explicit
      // hashOverlay: true — incremental forces it on.
      expect(idx.equalsHash(13), isNotNull);
      expect(idx.equalsHash(13)!.single, 3);
    });

    test('SetNodeProp mutates the index in place — no rebuild', () {
      final db = _db(n: 5);
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(incremental: true),
      ));
      // Same identity post-mutation — drop-and-rebuild would have
      // produced a NEW instance.
      db.state.applySetNodeProp(const Vid(2), age, const PropInt(99));
      expect(identical(db.getNodeIndex('age'), idx), isTrue);
      final mutated = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(mutated.length, 5);
      // Range query: lazy resort happens here.
      expect(mutated.lowerBound(99), 4);
      expect(mutated.equalsHash(99)!.single, 2);
    });

    test('DelNodeProp removes the entry in place', () {
      final db = _db(n: 5);
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(incremental: true),
      ));
      db.state.applyDelNodeProp(const Vid(2), age);
      final idx = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(idx.length, 4);
      expect(idx.equalsHash(12), isNull);
      // Trigger lazy resort + verify ordering.
      idx.lowerBound(0);
      expect(idx.sortedValues, [10, 11, 13, 14]);
    });

    test('DelNode drops the vid from every covering incremental index', () {
      final db = _db(n: 5);
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(incremental: true),
      ));
      db.state.applyDelNode(const Vid(2));
      // Same instance — no rebuild.
      expect(identical(db.getNodeIndex('age'), idx), isTrue);
      final mutated = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(mutated.length, 4);
      mutated.lowerBound(0); // trigger lazy resort
      expect(mutated.sortedValues, [10, 11, 13, 14]);
    });

    test('AddNode with props inserts incrementally — no rebuild', () {
      final db = _db(n: 5);
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(incremental: true),
      ));
      final v = db.state.allocVid();
      db.state.applyAddNode(
        v,
        logicalId: 'new',
        labelIds: [0],
        props: {age: const PropInt(99)},
      );
      expect(identical(db.getNodeIndex('age'), idx), isTrue);
      final mutated = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(mutated.length, 6);
      expect(mutated.equalsHash(99)!.single, v.value);
    });

    test('non-int incremental indexes fall back to drop-and-rebuild', () {
      final db = _db(n: 5);
      final name = db.internPropKey('name');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setString(i, name, 'n$i');
      }
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'name',
        keyId: name,
        kind: const EqualityRange(incremental: true),
      ));
      db.state.applySetNodeProp(const Vid(2), name, const PropString('zzz'));
      // String column doesn't have an incremental path → fall back =
      // a fresh instance.
      expect(identical(db.getNodeIndex('name'), idx), isFalse);
    });

    test('mutations leave the sorted array dirty until a range query',
        () {
      final db = _db(n: 5);
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(incremental: true),
      )) as IntEqualityRangeIndex;
      // Mutate. The sorted array is now stale (the hash carries the
      // truth) — but equalsHash works immediately.
      db.state.applySetNodeProp(const Vid(0), age, const PropInt(999));
      expect(idx.equalsHash(999), isNotNull);
      // lowerBound triggers the lazy resort.
      expect(idx.lowerBound(999), 4);
      expect(idx.sortedValues.last, 999);
    });
  });
}
