import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

GraphDb _db() {
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const ['Person', 'Company'],
    edgeTypeNames: const ['rel'],
    vidSpace: 64,
    eidSpace: 64,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('findNodeByProp / findNodesByProp', () {
    test('finds by string prop — read-your-writes, label-scoped', () async {
      final db = _db();
      final person = db.internLabel('Person');
      final company = db.internLabel('Company');
      final name = db.internPropKey('name');

      final ada = await db.runTransaction((txn) => txn
          .addNode(labelIds: [person], props: {name: const PropString('Ada')}));
      await db.runTransaction((txn) => txn
          .addNode(labelIds: [person], props: {name: const PropString('Bob')}));
      // A Company also named 'Ada' must not match a Person query.
      await db.runTransaction((txn) => txn.addNode(
          labelIds: [company], props: {name: const PropString('Ada')}));

      // No mergeNow() — the lookup must already see the committed nodes.
      expect(db.findNodeByProp(person, name, const PropString('Ada'))?.value,
          ada.value);
      expect(db.findNodeByProp(person, name, const PropString('Nobody')),
          isNull);
    });

    test('findNodesByProp returns every match, ascending by vid', () async {
      final db = _db();
      final person = db.internLabel('Person');
      final age = db.internPropKey('age');

      final a = await db.runTransaction(
          (txn) => txn.addNode(labelIds: [person], props: {age: const PropInt(30)}));
      final b = await db.runTransaction(
          (txn) => txn.addNode(labelIds: [person], props: {age: const PropInt(30)}));
      await db.runTransaction(
          (txn) => txn.addNode(labelIds: [person], props: {age: const PropInt(31)}));

      expect(
        db.findNodesByProp(person, age, const PropInt(30)).map((v) => v.value),
        [a.value, b.value],
      );
    });

    test('an absent property never matches a non-null value', () async {
      final db = _db();
      final person = db.internLabel('Person');
      final name = db.internPropKey('name');
      await db.runTransaction((txn) => txn.addNode(labelIds: [person])); // no name

      expect(db.findNodeByProp(person, name, const PropString('x')), isNull);
      expect(db.findNodesByProp(person, name, const PropString('x')), isEmpty);
    });

    test('a deleted node drops out of the results (RYW)', () async {
      final db = _db();
      final person = db.internLabel('Person');
      final name = db.internPropKey('name');
      final ada = await db.runTransaction((txn) => txn
          .addNode(labelIds: [person], props: {name: const PropString('Ada')}));
      expect(db.findNodeByProp(person, name, const PropString('Ada'))?.value,
          ada.value);

      await db.runTransaction((txn) => txn.delNode(ada));
      expect(
          db.findNodeByProp(person, name, const PropString('Ada')), isNull);
    });
  });
}
