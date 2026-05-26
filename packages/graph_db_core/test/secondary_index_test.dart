import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Tiny fixture builder — 5 nodes, a couple of edges, label 0 on all.

({GraphDb db, MutableGraphState state}) _smallDb({int nodeCount = 5}) {
  final srcs = Uint32List.fromList([0, 1, 2, 3, 0]);
  final dsts = Uint32List.fromList([1, 2, 3, 4, 4]);
  final edgeTypes = Uint32List.fromList([0, 0, 0, 0, 0]);
  final labelOf = Uint32List(nodeCount); // all 0
  final state = MutableGraphState.fromFixture(
    nodeCount: nodeCount,
    srcs: srcs,
    dsts: dsts,
    edgeTypes: edgeTypes,
    labelOf: labelOf,
    labelNames: const ['Node'],
    edgeTypeNames: const ['link'],
  );
  return (db: GraphDb.fromState(state), state: state);
}

void main() {
  group('IntEqualityRangeIndex', () {
    test('equality + range over an int_ column', () {
      final (:db, :state) = _smallDb();
      final age = db.internPropKey('age');
      // ages: 30, 30, 40, 50, 50
      state.nodeProps.setInt(0, age, 30);
      state.nodeProps.setInt(1, age, 30);
      state.nodeProps.setInt(2, age, 40);
      state.nodeProps.setInt(3, age, 50);
      state.nodeProps.setInt(4, age, 50);

      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age_idx',
        keyId: age,
        kind: const EqualityRange(),
      )) as IntEqualityRangeIndex;

      expect(idx.length, 5);
      expect(idx.sortedValues, [30, 30, 40, 50, 50]);
      // equality
      final lo30 = idx.lowerBound(30);
      final hi30 = idx.upperBound(30);
      expect([for (var i = lo30; i < hi30; i++) idx.vidAt(i)]..sort(), [0, 1]);
      // < 50
      expect(idx.lowerBound(50), 3);
      // > 30
      expect(idx.upperBound(30), 2);
      // missing value
      expect(idx.lowerBound(45), 3);
      expect(idx.upperBound(45), 3);
    });

    test('hash overlay returns the matching vids', () {
      final (:db, :state) = _smallDb();
      final score = db.internPropKey('score');
      state.nodeProps.setInt(0, score, 100);
      state.nodeProps.setInt(1, score, 200);
      state.nodeProps.setInt(2, score, 100);

      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'score_idx',
        keyId: score,
        kind: const EqualityRange(hashOverlay: true),
      )) as IntEqualityRangeIndex;

      final hit = idx.equalsHash(100)!;
      expect(hit.toList()..sort(), [0, 2]);
      expect(idx.equalsHash(999), isNull);
    });

    test('skips tombstoned and explicit-null vids', () {
      final (:db, :state) = _smallDb();
      final age = db.internPropKey('age');
      state.nodeProps.setInt(0, age, 10);
      state.nodeProps.setInt(1, age, 20);
      state.nodeProps.setInt(2, age, 30);
      state.nodeProps.setNull(3, age); // explicit null — excluded
      // vid 4 — never set — excluded

      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(),
      )) as IntEqualityRangeIndex;

      expect(idx.length, 3);
      expect(idx.sortedValues, [10, 20, 30]);
    });
  });

  group('DoubleEqualityRangeIndex', () {
    test('equality + range over a double_ column', () {
      final (:db, :state) = _smallDb();
      final r = db.internPropKey('ratio');
      state.nodeProps.setDouble(0, r, 1.5);
      state.nodeProps.setDouble(1, r, 2.5);
      state.nodeProps.setDouble(2, r, 1.5);
      state.nodeProps.setDouble(3, r, 3.0);

      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'ratio_idx',
        keyId: r,
        kind: const EqualityRange(hashOverlay: true),
      )) as DoubleEqualityRangeIndex;

      expect(idx.length, 4);
      final lo = idx.lowerBound(1.5);
      final hi = idx.upperBound(1.5);
      expect([for (var i = lo; i < hi; i++) idx.vidAt(i)]..sort(), [0, 2]);
      expect(idx.equalsHash(1.5)!.toList()..sort(), [0, 2]);
    });
  });

  group('StringIdEqualityRangeIndex', () {
    test('equality + range over a stringId column', () {
      final (:db, :state) = _smallDb();
      final tag = db.internPropKey('tag');
      // Use the interner — stringIds happen to come back sorted by
      // insertion order, not lexicographic.
      final red = db.internLabel('red');
      final blue = db.internLabel('blue');
      final green = db.internLabel('green');
      state.nodeProps.setStringId(0, tag, red);
      state.nodeProps.setStringId(1, tag, blue);
      state.nodeProps.setStringId(2, tag, red);
      state.nodeProps.setStringId(3, tag, green);

      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'tag_idx',
        keyId: tag,
        kind: const EqualityRange(),
      )) as StringIdEqualityRangeIndex;

      // sort key is the interned id (numeric), not the label string
      expect(idx.length, 4);
      final lo = idx.lowerBound(red);
      final hi = idx.upperBound(red);
      expect([for (var i = lo; i < hi; i++) idx.vidAt(i)]..sort(), [0, 2]);
    });
  });

  group('StringEqualityRangeIndex', () {
    test('lexicographic equality + range over a string column', () {
      final (:db, :state) = _smallDb();
      final n = db.internPropKey('name');
      state.nodeProps.setString(0, n, 'Charlie');
      state.nodeProps.setString(1, n, 'Alice');
      state.nodeProps.setString(2, n, 'Bob');
      state.nodeProps.setString(3, n, 'Alice');

      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'name_idx',
        keyId: n,
        kind: const EqualityRange(hashOverlay: true),
      )) as StringEqualityRangeIndex;

      expect(idx.sortedValues, ['Alice', 'Alice', 'Bob', 'Charlie']);
      // equality
      final loA = idx.lowerBound('Alice');
      final hiA = idx.upperBound('Alice');
      expect([for (var i = loA; i < hiA; i++) idx.vidAt(i)]..sort(), [1, 3]);
      // lexicographic range  Bob..Charlie
      final loB = idx.lowerBound('Bob');
      final hiC = idx.upperBound('Charlie');
      expect([for (var i = loB; i < hiC; i++) idx.vidAt(i)]..sort(),
          [0, 2]);
      // hash overlay
      expect(idx.equalsHash('Alice')!.toList()..sort(), [1, 3]);
      expect(idx.equalsHash('Zelda'), isNull);
    });
  });

  group('BoolEqualityRangeIndex', () {
    test('cutoff splits false-vids from true-vids', () {
      final (:db, :state) = _smallDb();
      final active = db.internPropKey('active');
      state.nodeProps.setBool(0, active, true);
      state.nodeProps.setBool(1, active, false);
      state.nodeProps.setBool(2, active, true);
      state.nodeProps.setBool(3, active, false);
      state.nodeProps.setBool(4, active, true);

      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'active_idx',
        keyId: active,
        kind: const EqualityRange(),
      )) as BoolEqualityRangeIndex;

      expect(idx.length, 5);
      expect(idx.cutoff, 2);
      final (fLo, fHi) = idx.equalRange(false);
      expect([for (var i = fLo; i < fHi; i++) idx.vidAt(i)]..sort(), [1, 3]);
      final (tLo, tHi) = idx.equalRange(true);
      expect([for (var i = tLo; i < tHi; i++) idx.vidAt(i)]..sort(),
          [0, 2, 4]);
    });
  });

  group('Registry', () {
    test('rejects duplicate index names', () {
      final (:db, :state) = _smallDb();
      final k = db.internPropKey('k');
      state.nodeProps.setInt(0, k, 1);
      db.createNodePropertyIndex(IndexSpec(
        name: 'dup',
        keyId: k,
        kind: const EqualityRange(),
      ));
      expect(
        () => db.createNodePropertyIndex(IndexSpec(
          name: 'dup',
          keyId: k,
          kind: const EqualityRange(),
        )),
        throwsA(isA<Object>()),
      );
    });

    test('rejects an undeclared column', () {
      final db = _smallDb().db;
      final unused = db.internPropKey('nope');
      expect(
        () => db.createNodePropertyIndex(IndexSpec(
          name: 'x',
          keyId: unused,
          kind: const EqualityRange(),
        )),
        throwsA(isA<Object>()),
      );
    });

    test('drop returns the removed index and clears the registry slot', () {
      final (:db, :state) = _smallDb();
      final k = db.internPropKey('age');
      state.nodeProps.setInt(0, k, 1);
      final created = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: k,
        kind: const EqualityRange(),
      ));
      expect(db.getNodeIndex('age'), same(created));
      final dropped = db.dropNodeIndex('age');
      expect(dropped, same(created));
      expect(db.getNodeIndex('age'), isNull);
      expect(db.dropNodeIndex('age'), isNull);
    });

    test('node and edge registries are independent', () {
      final (:db, :state) = _smallDb();
      final k = db.internPropKey('w');
      state.nodeProps.setInt(0, k, 1);
      state.edgeProps.setInt(0, k, 9);
      final n = db.createNodePropertyIndex(IndexSpec(
        name: 'w', keyId: k, kind: const EqualityRange(),
      ));
      final e = db.createEdgePropertyIndex(IndexSpec(
        name: 'w', keyId: k, kind: const EqualityRange(),
      ));
      expect(n, isNot(same(e)));
      expect(db.getNodeIndex('w'), same(n));
      expect(db.getEdgeIndex('w'), same(e));
    });
  });

  group('Size-event hook', () {
    test('fires when ratio ≥ 25% of CSR', () {
      // Tiny graph (5 nodes, 5 edges) → CSR is small → adding a wide
      // string index easily exceeds 25%.
      final (:db, :state) = _smallDb();
      final n = db.internPropKey('name');
      for (var v = 0; v < 5; v++) {
        state.nodeProps.setString(v, n, 'somewhat_longish_string_$v');
      }
      IndexSizeEvent? caught;
      db.onIndexSizeEvent = (e) => caught = e;
      db.createNodePropertyIndex(IndexSpec(
        name: 'big',
        keyId: n,
        kind: const EqualityRange(hashOverlay: true),
      ));
      expect(caught, isNotNull);
      expect(caught!.severity, IndexSizeSeverity.warn);
      expect(caught!.ratio, greaterThanOrEqualTo(kIndexSizeWarnThreshold));
      expect(caught!.spec.name, 'big');
    });

    test('does not fire for a tiny index well under the threshold', () {
      // 1024 nodes → CSR ~ 16KB topology. Indexing 1 int = ~12 bytes.
      // Ratio ≪ 25 %.
      final nodeCount = 1024;
      final srcs = Uint32List.fromList([0, 1, 2]);
      final dsts = Uint32List.fromList([1, 2, 3]);
      final edgeTypes = Uint32List.fromList([0, 0, 0]);
      final labelOf = Uint32List(nodeCount);
      final state = MutableGraphState.fromFixture(
        nodeCount: nodeCount,
        srcs: srcs,
        dsts: dsts,
        edgeTypes: edgeTypes,
        labelOf: labelOf,
        labelNames: const ['Node'],
        edgeTypeNames: const ['e'],
      );
      final db = GraphDb.fromState(state);
      final k = db.internPropKey('age');
      state.nodeProps.setInt(0, k, 42);
      var fired = false;
      db.onIndexSizeEvent = (_) => fired = true;
      db.createNodePropertyIndex(IndexSpec(
        name: 'small',
        keyId: k,
        kind: const EqualityRange(),
      ));
      expect(fired, isFalse);
    });
  });
}
