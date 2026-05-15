import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

void main() {
  test('intern is monotonic per kind and round-trips', () {
    final s = StringInterner();
    expect(s.internLabel('Person'), 0);
    expect(s.internLabel('Company'), 1);
    expect(s.internLabel('Person'), 0); // same id on re-intern
    expect(s.labelOf(0), 'Person');
    expect(s.labelOf(1), 'Company');
    expect(s.labelOf(2), null);
  });

  test('kinds have independent id spaces', () {
    final s = StringInterner();
    expect(s.internLabel('X'), 0);
    expect(s.internEdgeType('X'), 0);
    expect(s.internPropKey('X'), 0);
    expect(s.labelOf(0), 'X');
    expect(s.edgeTypeOf(0), 'X');
    expect(s.propKeyOf(0), 'X');
  });

  test('counts track entries', () {
    final s = StringInterner();
    s.internLabel('a');
    s.internLabel('b');
    s.internEdgeType('x');
    expect(s.labelCount, 2);
    expect(s.edgeTypeCount, 1);
    expect(s.propKeyCount, 0);
  });
}
