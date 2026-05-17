import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

GraphDb _smallDb({int nodeCount = 5}) {
  final state = MutableGraphState.fromFixture(
    nodeCount: nodeCount,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(nodeCount),
    labelNames: const ['Node'],
    edgeTypeNames: const [],
    vidSpace: 16,
    eidSpace: 16,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('5A: index updates on mutation', () {
    test('SetNodeProp triggers index rebuild', () {
      final db = _smallDb();
      final age = db.internPropKey('age');
      db.state.nodeProps.setInt(0, age, 30);
      db.state.nodeProps.setInt(1, age, 40);
      final idx = db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(),
      )) as IntEqualityRangeIndex;
      expect(idx.length, 2);
      // Mutate via the applicator path (state-level)
      db.state.applySetNodeProp(const Vid(2), age, const PropInt(35));
      final refreshed = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(refreshed.length, 3);
      expect(refreshed.sortedValues, [30, 35, 40]);
    });

    test('DelNodeProp triggers index rebuild', () {
      final db = _smallDb();
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(),
      ));
      db.state.applyDelNodeProp(const Vid(2), age);
      final refreshed = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(refreshed.length, 4);
      expect(refreshed.sortedValues, [10, 11, 13, 14]);
    });

    test('applyDelNode removes vid from every covering index', () {
      final db = _smallDb();
      final age = db.internPropKey('age');
      final name = db.internPropKey('name');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
        db.state.nodeProps.setString(i, name, 'n$i');
      }
      db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(),
      ));
      db.createNodePropertyIndex(IndexSpec(
        name: 'name',
        keyId: name,
        kind: const EqualityRange(),
      ));
      db.state.applyDelNode(const Vid(2));
      final ageIdx = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      final nameIdx = db.getNodeIndex('name')! as StringEqualityRangeIndex;
      expect(ageIdx.length, 4);
      expect(nameIdx.length, 4);
      expect(ageIdx.sortedValues, [10, 11, 13, 14]);
    });

    test('AddNode with props lands in the index immediately', () {
      final db = _smallDb();
      final age = db.internPropKey('age');
      for (var i = 0; i < 5; i++) {
        db.state.nodeProps.setInt(i, age, 10 + i);
      }
      db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(),
      ));
      final v = db.state.allocVid();
      db.state.applyAddNode(
        v,
        logicalId: 'new',
        labelIds: [0],
        props: {age: const PropInt(99)},
      );
      final idx = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(idx.length, 6);
      expect(idx.sortedValues.last, 99);
    });

    test('unique index rejects duplicate on SetNodeProp', () {
      final db = _smallDb();
      final email = db.internPropKey('email');
      db.state.nodeProps.setString(0, email, 'a@x');
      db.state.nodeProps.setString(1, email, 'b@x');
      db.createNodePropertyIndex(IndexSpec(
        name: 'email_uq',
        keyId: email,
        kind: const EqualityRange(unique: true),
      ));
      // Setting vid 2 to an existing value violates uniqueness.
      expect(
        () => db.state.applySetNodeProp(
          const Vid(2),
          email,
          const PropString('a@x'),
        ),
        throwsA(isA<ConstraintViolation>()),
      );
      // Existing index unchanged + the column write didn't happen.
      expect(db.state.nodeProps.has(2, email), isFalse);
    });

    test('unique index allows re-setting the same vid to the same value',
        () {
      final db = _smallDb();
      final email = db.internPropKey('email');
      db.state.nodeProps.setString(0, email, 'a@x');
      db.createNodePropertyIndex(IndexSpec(
        name: 'email_uq',
        keyId: email,
        kind: const EqualityRange(unique: true),
      ));
      // Same vid + same value → idempotent, no throw.
      expect(
        () => db.state.applySetNodeProp(
          const Vid(0),
          email,
          const PropString('a@x'),
        ),
        returnsNormally,
      );
    });

    test('non-unique index allows duplicates', () {
      final db = _smallDb();
      final age = db.internPropKey('age');
      db.state.nodeProps.setInt(0, age, 30);
      db.createNodePropertyIndex(IndexSpec(
        name: 'age',
        keyId: age,
        kind: const EqualityRange(),
      ));
      // Setting a duplicate value on a non-unique index — no throw.
      expect(
        () => db.state.applySetNodeProp(
          const Vid(1),
          age,
          const PropInt(30),
        ),
        returnsNormally,
      );
      final idx = db.getNodeIndex('age')! as IntEqualityRangeIndex;
      expect(idx.length, 2);
    });

    test('AddNode with unique prop rejects duplicate', () {
      final db = _smallDb();
      final email = db.internPropKey('email');
      db.state.nodeProps.setString(0, email, 'a@x');
      db.createNodePropertyIndex(IndexSpec(
        name: 'email_uq',
        keyId: email,
        kind: const EqualityRange(unique: true),
      ));
      final v = db.state.allocVid();
      expect(
        () => db.state.applyAddNode(
          v,
          logicalId: 'dup',
          labelIds: [0],
          props: {email: const PropString('a@x')},
        ),
        throwsA(isA<ConstraintViolation>()),
      );
    });
  });
}
