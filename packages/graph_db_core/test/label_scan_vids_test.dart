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
    labelNames: const ['Person'],
    edgeTypeNames: const ['rel'],
    vidSpace: 64,
    eidSpace: 64,
  );
  return GraphDb.fromState(state);
}

void main() {
  group('labelScanVids', () {
    test('yields the same vids as labelScan, as typed Vids', () async {
      final db = _db();
      final person = db.internLabel('Person');
      final name = db.internPropKey('name');
      final a = await db.runTransaction((txn) => txn
          .addNode(labelIds: [person], props: {name: const PropString('A')}));
      final b = await db.runTransaction((txn) => txn
          .addNode(labelIds: [person], props: {name: const PropString('B')}));

      final viaVids = db.labelScanVids(person).map((v) => v.value).toList();
      expect(viaVids, db.labelScan(person).toList(),
          reason: 'same contents as the raw scan');
      expect(viaVids, [a.value, b.value]);
    });

    test('elements drop straight into the typed accessors (no Vid wrap)',
        () async {
      final db = _db();
      final person = db.internLabel('Person');
      final name = db.internPropKey('name');
      await db.runTransaction((txn) => txn
          .addNode(labelIds: [person], props: {name: const PropString('A')}));
      await db.runTransaction((txn) => txn
          .addNode(labelIds: [person], props: {name: const PropString('B')}));

      final names = [
        for (final v in db.labelScanVids(person)) db.getNodeStringProp(v, name),
      ];
      expect(names, ['A', 'B']);
    });

    test('read-your-writes — a fresh commit is visible without mergeNow',
        () async {
      final db = _db();
      final person = db.internLabel('Person');
      await db.runTransaction((txn) => txn.addNode(labelIds: [person]));
      expect(db.labelScanVids(person).length, 1);
    });
  });
}
