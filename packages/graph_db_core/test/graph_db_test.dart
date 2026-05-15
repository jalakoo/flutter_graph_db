import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_core/samples.dart';
import 'package:test/test.dart';

void main() {
  late SocialGraph sg;
  late GraphDb db;

  setUp(() {
    sg = SocialGraph.build();
    db = sg.db;
  });

  test('fixture has 12 people, 4 companies, and the expected edges', () {
    expect(db.nodeCount, 16);
    expect(db.edgeCount, greaterThan(0));
    expect(db.labelScan(sg.personLabel).length, 12);
    expect(db.labelScan(sg.companyLabel).length, 4);
  });

  test('Alice has 3 knows, 1 worksAt, 1 founded out-edges', () {
    final alice = sg.people[0]; // Alice
    final byType = <int, int>{};
    db.forEachOutNeighbor(alice, (dst, eid, t) {
      byType[t] = (byType[t] ?? 0) + 1;
    });
    expect(byType[sg.knowsEdge], 3);
    expect(byType[sg.worksAtEdge], 1);
    expect(byType[sg.foundedEdge], 1);
  });

  test('Acme has 3 incoming worksAt edges', () {
    final acme = sg.companies[0]; // Acme
    var worksAt = 0;
    db.forEachInNeighbor(acme, (src, eid, t) {
      if (t == sg.worksAtEdge) worksAt++;
    });
    expect(worksAt, 3);
  });

  test('property accessors return the fixture values', () {
    final alice = sg.people[0];
    expect(db.getNodeStringProp(alice, sg.nameKey), 'Alice');
    expect(db.getNodeIntProp(alice, sg.ageKey), 34);
    expect(db.getNodeStringProp(alice, sg.titleKey), 'Engineer');

    final acme = sg.companies[0];
    expect(db.getNodeStringProp(acme, sg.nameKey), 'Acme');
    expect(db.getNodeIntProp(acme, sg.foundedYearKey), 1947);
  });

  test('boundary getNodeProp wraps the raw value in a PropValue', () {
    final alice = sg.people[0];
    expect(db.getNodeProp(alice, sg.nameKey), const PropString('Alice'));
    expect(db.getNodeProp(alice, sg.ageKey), const PropInt(34));
  });

  test('intern lookups round-trip', () {
    expect(db.labelName(sg.personLabel), 'Person');
    expect(db.labelName(sg.companyLabel), 'Company');
    expect(db.edgeTypeName(sg.knowsEdge), 'knows');
    expect(db.edgeTypeName(sg.worksAtEdge), 'worksAt');
    expect(db.edgeTypeName(sg.foundedEdge), 'founded');
    expect(db.propKeyName(sg.nameKey), 'name');
  });

  test('labelOf returns the right label per node', () {
    for (final p in sg.people) {
      expect(db.labelOf(p), sg.personLabel);
    }
    for (final c in sg.companies) {
      expect(db.labelOf(c), sg.companyLabel);
    }
  });
}
