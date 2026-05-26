import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

({GraphDb db, MutableGraphState state}) _db({int n = 5}) {
  final state = MutableGraphState.fromFixture(
    nodeCount: n,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(n), // all label 0
    labelNames: const ['Person'],
    edgeTypeNames: const [],
    vidSpace: n + 16,
    eidSpace: 16,
  );
  return (db: GraphDb.fromState(state), state: state);
}

void main() {
  group('6C: constraint catalog', () {
    test('declareConstraint via txn registers the spec', () async {
      final (:db, :state) = _db();
      final personLabel = db.internLabel('Person');
      final emailKey = db.internPropKey('email');
      // Need a column declared so the auto-index creation can proceed
      state.nodeProps.setString(0, emailKey, 'a@x');
      await db.runTransaction((txn) {
        txn.declareConstraint(UniqueConstraint(
          name: 'person_email_uq',
          labelId: personLabel,
          keyId: emailKey,
        ));
      });
      expect(db.constraints.length, 1);
      expect(db.constraints.get('person_email_uq'),
          isA<UniqueConstraint>());
      // Underlying unique index was auto-created.
      expect(db.getNodeIndex('__uq_person_email_uq'), isNotNull);
    });

    test('declare validates existing data (unique rejects dups)',
        () async {
      final (:db, :state) = _db();
      final personLabel = db.internLabel('Person');
      final emailKey = db.internPropKey('email');
      state.nodeProps.setString(0, emailKey, 'a@x');
      state.nodeProps.setString(1, emailKey, 'a@x'); // duplicate
      await expectLater(
        () => db.runTransaction((txn) {
          txn.declareConstraint(UniqueConstraint(
            name: 'person_email_uq',
            labelId: personLabel,
            keyId: emailKey,
          ));
        }),
        throwsA(isA<ConstraintViolation>()),
      );
      // Failed declare doesn't pollute the catalog.
      expect(db.constraints.length, 0);
    });

    test('declare validates existing data (existence rejects missing)',
        () async {
      final (:db, :state) = _db();
      final personLabel = db.internLabel('Person');
      final nameKey = db.internPropKey('name');
      // vid 0 has a name, vid 1 doesn't
      state.nodeProps.setString(0, nameKey, 'Ada');
      await expectLater(
        () => db.runTransaction((txn) {
          txn.declareConstraint(ExistenceConstraint(
            name: 'person_name_exists',
            labelId: personLabel,
            keyId: nameKey,
          ));
        }),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('existence constraint rejects AddNode missing the key', () async {
      final (:db, :state) = _db(n: 0);
      final personLabel = db.internLabel('Person');
      final nameKey = db.internPropKey('name');
      // Declare on an empty graph (no validation needed).
      await db.runTransaction((txn) {
        txn.declareConstraint(ExistenceConstraint(
          name: 'name_required',
          labelId: personLabel,
          keyId: nameKey,
        ));
      });
      await expectLater(
        () => db.runTransaction((txn) {
          txn.addNode(labelIds: [personLabel]); // no name prop
        }),
        throwsA(isA<ConstraintViolation>()),
      );
      // Adding with the required prop works.
      late Vid v;
      await db.runTransaction((txn) {
        v = txn.addNode(
          labelIds: [personLabel],
          props: {nameKey: const PropString('Ada')},
        );
      });
      // The previously-rolled-back addNode consumed vid 0 per §3.6
      // (ids never reused); the successful one got vid 1.
      expect(v.value, 1);
      expect(state.isNodeVisible(v), isTrue);
    });

    test('existence constraint rejects DelNodeProp on a covered label',
        () async {
      final db = _db(n: 0).db;
      final personLabel = db.internLabel('Person');
      final nameKey = db.internPropKey('name');
      await db.runTransaction((txn) {
        txn.declareConstraint(ExistenceConstraint(
          name: 'name_required',
          labelId: personLabel,
          keyId: nameKey,
        ));
      });
      late Vid v;
      await db.runTransaction((txn) {
        v = txn.addNode(
          labelIds: [personLabel],
          props: {nameKey: const PropString('Ada')},
        );
      });
      await expectLater(
        () => db.runTransaction((txn) {
          txn.delNodeProp(v, nameKey);
        }),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('dropConstraint removes from catalog', () async {
      final db = _db().db;
      final personLabel = db.internLabel('Person');
      final nameKey = db.internPropKey('name');
      // Declare on empty data
      await db.runTransaction((txn) {
        txn.declareConstraint(UniqueConstraint(
          name: 'uq',
          labelId: personLabel,
          keyId: nameKey,
        ));
      });
      expect(db.constraints.length, 1);
      await db.runTransaction((txn) {
        txn.dropConstraint('uq');
      });
      expect(db.constraints.length, 0);
    });

    test('dropConstraint idempotent — unknown name no-op', () async {
      final db = _db().db;
      // Just ensures no throw.
      await db.runTransaction((txn) {
        txn.dropConstraint('does-not-exist');
      });
      expect(db.constraints.length, 0);
    });
  });

  group('6A: observable LSN', () {
    test('currentLsn / nextLsn advance with each commit', () async {
      final db = _db().db;
      final lsnBefore = db.nextLsn;
      await db.runTransaction((txn) {
        txn.addNode(labelIds: [0]);
      });
      // 1 BeginTxn + 1 AddNode + 1 CommitTxn = 3 LSNs consumed.
      expect(db.nextLsn, lsnBefore + 3);
      expect(db.currentLsn, db.nextLsn - 1);
    });

    test('currentLsn is -1 when no op has been applied', () {
      final db = _db().db;
      expect(db.currentLsn, -1);
      expect(db.nextLsn, 0);
    });
  });
}
