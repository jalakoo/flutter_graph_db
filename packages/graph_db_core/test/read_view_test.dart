import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// A3.1 — `GraphReadView` + the two moved scans + `db.readView`.
///
/// Exercises the read seam against a real in-memory `db.readView`, with a
/// deliberately overlay-resident shape (writes committed but not merged)
/// plus one base-CSR node that gains a label via a label-override — so the
/// effective AND-scan's three arms (base scan / overlay-added / override)
/// all fire.
({GraphDb db, MutableGraphState state}) _emptyDb() {
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const ['Person', 'Admin', 'Robot'],
    edgeTypeNames: const ['KNOWS', 'OWNS'],
    vidSpace: 64,
    eidSpace: 64,
  );
  return (db: GraphDb.fromState(state), state: state);
}

void main() {
  group('A3.1: GraphReadView via db.readView', () {
    late GraphDb db;
    late MutableGraphState state;
    late int person, admin, robot, knows, age, name, since;
    late Vid v0, v1, v2, v3;
    late Eid e0;

    setUp(() async {
      (:db, :state) = _emptyDb();
      person = db.internLabel('Person');
      admin = db.internLabel('Admin');
      robot = db.internLabel('Robot');
      knows = db.internEdgeType('KNOWS');
      db.internEdgeType('OWNS');
      age = db.internPropKey('age');
      name = db.internPropKey('name');
      since = db.internPropKey('since');

      // Phase 1: three base nodes + one edge, then merge into the CSR so
      // they become base-CSR rows (so a later override exercises the
      // labelOverride arm).
      await db.runTransaction((txn) {
        v0 = txn.addNode(labelIds: [person], props: {age: const PropInt(30)});
        v1 = txn.addNode(labelIds: [person, admin]);
        v2 = txn.addNode(labelIds: [robot]);
        e0 = txn.addEdge(
          src: v0,
          dst: v2,
          typeId: knows,
          props: {since: const PropInt(2020)},
        );
      });
      state.mergeNow();

      // Phase 2 (overlay-resident, no merge): add an overlay node, grant
      // v2 the Person label (override on a base node), delete v1.
      await db.runTransaction((txn) {
        v3 = txn.addNode(labelIds: [person]);
        txn.setNodeLabels(v2, added: [person], removed: const []);
        txn.delNode(v1);
      });
    });

    test('db.readView returns a GraphReadView', () {
      final GraphReadView view = db.readView;
      expect(view, isNotNull);
    });

    test('scanNodes yields every visible vid (deleted skipped)', () {
      final got = db.readView.scanNodes().map((v) => v.value).toSet();
      expect(got, {v0.value, v2.value, v3.value}); // v1 deleted
    });

    test('labelScanAll: single label, effective (base + override + added)', () {
      final got =
          db.readView.labelScanAll([person]).map((v) => v.value).toSet();
      // v0 base Person, v2 gained Person via override, v3 overlay-added.
      // v1 was Person but deleted.
      expect(got, {v0.value, v2.value, v3.value});
    });

    test('labelScanAll: multi-label AND', () {
      // v1 had {Person, Admin} but is deleted → nothing matches.
      expect(db.readView.labelScanAll([person, admin]), isEmpty);
      // v2 effective set is {Robot, Person} after the override.
      expect(
        db.readView.labelScanAll([person, robot]).map((v) => v.value).toSet(),
        {v2.value},
      );
    });

    test('labelScanAll: empty label list falls back to scanNodes', () {
      expect(
        db.readView.labelScanAll(const []).map((v) => v.value).toSet(),
        db.readView.scanNodes().map((v) => v.value).toSet(),
      );
    });

    test('forEachOutNeighbor / forEachInNeighbor (overlay-aware)', () {
      final out = <(int, int, int)>[];
      db.readView.forEachOutNeighbor(
        v0,
        (dst, eid, et) => out.add((dst.value, eid.value, et)),
      );
      expect(out, [(v2.value, e0.value, knows)]);

      final inn = <(int, int, int)>[];
      db.readView.forEachInNeighbor(
        v2,
        (src, eid, et) => inn.add((src.value, eid.value, et)),
      );
      expect(inn, [(v0.value, e0.value, knows)]);
    });

    test('labelsOf / hasLabel are effective', () {
      expect(db.readView.labelsOf(v2).toSet(), {robot, person});
      expect(db.readView.hasLabel(v2, person), isTrue);
      expect(db.readView.hasLabel(v0, admin), isFalse);
    });

    test('nodeProp / edgeProp (boxed; null when absent)', () {
      expect(db.readView.nodeProp(v0, age), const PropInt(30));
      expect(db.readView.nodeProp(v0, name), isNull); // never set
      expect(db.readView.edgeProp(e0, since), const PropInt(2020));
    });

    test('catalog: non-interning name<->id resolution', () {
      expect(db.readView.labelId('Person'), person);
      expect(db.readView.labelId('Nope'), isNull);
      expect(db.readView.edgeTypeId('KNOWS'), knows);
      expect(db.readView.propKeyId('age'), age);
      expect(db.readView.labelName(person), 'Person');
    });
  });
}
