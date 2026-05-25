import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

GraphDb _db() => GraphDb.fromState(MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const [],
      edgeTypeNames: const [],
      vidSpace: 64,
      eidSpace: 64,
    ));

void main() {
  group('string-keyed overloads', () {
    test('addNodeNamed interns labels + keys; node is findable', () async {
      final db = _db();
      final ada = await db.runTransaction((txn) => txn.addNodeNamed(
            labels: ['Person'],
            props: {'name': const PropString('Ada')},
          ));

      final person = db.labelId('Person');
      final name = db.propKeyId('name');
      expect(person, isNotNull);
      expect(name, isNotNull);
      expect(db.hasLabel(ada, person!), isTrue);
      expect(db.getNodeStringProp(ada, name!), 'Ada');
      // read-your-writes via the string-resolved key
      expect(
          db.findNodeByProp(name, const PropString('Ada'), label: person)?.value,
          ada.value);
    });

    test('addEdgeNamed interns the type + edge prop keys', () async {
      final db = _db();
      late final Vid a;
      late final Vid b;
      final eid = await db.runTransaction((txn) {
        a = txn.addNodeNamed(labels: ['Person']);
        b = txn.addNodeNamed(labels: ['Person']);
        return txn.addEdgeNamed(
          src: a,
          dst: b,
          type: 'KNOWS',
          props: {'since': const PropInt(2020)},
        );
      });

      final knows = db.edgeTypeId('KNOWS');
      final since = db.propKeyId('since');
      expect(knows, isNotNull);
      expect(db.getEdgeIntProp(eid, since!), 2020);

      var found = false;
      db.forEachOutNeighbor(a, (dst, e, type) {
        if (dst.value == b.value && type == knows) found = true;
      });
      expect(found, isTrue);
    });

    test('setNodePropNamed interns the key', () async {
      final db = _db();
      final ada =
          await db.runTransaction((txn) => txn.addNodeNamed(labels: ['Person']));
      await db.runTransaction(
          (txn) => txn.setNodePropNamed(ada, 'age', const PropInt(36)));
      expect(db.getNodeIntProp(ada, db.propKeyId('age')!), 36);
    });

    test('name resolvers return null for unknown names', () {
      final db = _db();
      expect(db.labelId('Nope'), isNull);
      expect(db.edgeTypeId('Nope'), isNull);
      expect(db.propKeyId('Nope'), isNull);
    });

    test('string-keyed methods throw without a wired interner', () {
      final db = _db();
      final txn = Transaction(0, db.state); // no interners wired
      expect(() => txn.addNodeNamed(labels: ['X']), throwsStateError);
    });
  });
}
