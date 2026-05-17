import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

GraphDb _db({int n = 5}) {
  final state = MutableGraphState.fromFixture(
    nodeCount: n,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(n),
    labelNames: const ['Node'],
    edgeTypeNames: const [],
    vidSpace: 16,
    eidSpace: 16,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('5B: deferred index updates', () {
    test('deferred=true queues rather than rebuilds inline', () {
      final db = _db();
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      db.createNodePropertyIndex(IndexSpec(
        name: 'age_d',
        keyId: age,
        kind: const EqualityRange(deferred: true),
      ));
      // Capture the index reference — it shouldn't be replaced by
      // sync rebuilds during mutations.
      final before = db.getNodeIndex('age_d');
      db.state.applySetNodeProp(const Vid(1), age, const PropInt(99));
      expect(db.state.pendingDeferredIndexUpdates, 1);
      // Same instance — not rebuilt yet.
      expect(identical(db.getNodeIndex('age_d'), before), isTrue);
      db.state.flushDeferredIndexUpdates();
      expect(db.state.pendingDeferredIndexUpdates, 0);
      final after = db.getNodeIndex('age_d')! as IntEqualityRangeIndex;
      expect(after.length, 5);
      expect(after.sortedValues.last, 99);
    });

    test('coalescing: many mutations → one rebuild on flush', () {
      final db = _db();
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      db.createNodePropertyIndex(IndexSpec(
        name: 'age_d',
        keyId: age,
        kind: const EqualityRange(deferred: true),
      ));
      // 5 mutations × same index → queue stays size 1 (the index name)
      for (var i = 0; i < 5; i++) {
        db.state.applySetNodeProp(Vid(i), age, PropInt(200 + i));
      }
      expect(db.state.pendingDeferredIndexUpdates, 1);
      db.state.flushDeferredIndexUpdates();
      final idx = db.getNodeIndex('age_d')! as IntEqualityRangeIndex;
      expect(idx.length, 5);
      expect(idx.sortedValues, [200, 201, 202, 203, 204]);
    });

    test('unique indexes ignore the deferred flag (sync regardless)',
        () {
      final db = _db();
      final email = db.internPropKey('email');
      db.state.nodeProps.setString(0, email, 'a@x');
      db.createNodePropertyIndex(IndexSpec(
        name: 'email_uq',
        keyId: email,
        kind: const EqualityRange(unique: true, deferred: true),
      ));
      // unique + deferred → effectively sync; duplicate still throws.
      expect(
        () => db.state.applySetNodeProp(
          const Vid(1),
          email,
          const PropString('a@x'),
        ),
        throwsA(isA<ConstraintViolation>()),
      );
    });
  });

  group('5C: priority flag + IndexPriority', () {
    test('IndexSpec.priority defaults to low', () {
      const s = IndexSpec(
        name: 'x', keyId: 1, kind: EqualityRange(),
      );
      expect(s.priority, IndexPriority.low);
    });

    test('priority: high preserved on the spec', () {
      const s = IndexSpec(
        name: 'x',
        keyId: 1,
        kind: EqualityRange(),
        priority: IndexPriority.high,
      );
      expect(s.priority, IndexPriority.high);
    });
  });
}
