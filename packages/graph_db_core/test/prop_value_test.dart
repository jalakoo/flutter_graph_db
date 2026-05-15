import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

void main() {
  test('scalar subclasses are value-equal', () {
    expect(const PropInt(7), const PropInt(7));
    expect(const PropInt(7) == const PropInt(8), false);
    expect(const PropDouble(1.5), const PropDouble(1.5));
    expect(const PropString('x'), const PropString('x'));
    expect(const PropBool(true), const PropBool(true));
    expect(const PropNull(), const PropNull());
  });

  test('different subclasses are never equal', () {
    expect(const PropInt(1) == const PropDouble(1), false);
    expect(const PropNull() == const PropBool(false), false);
  });

  test('sealed switch is exhaustive without default', () {
    String describe(PropValue v) {
      return switch (v) {
        PropInt() => 'int',
        PropDouble() => 'double',
        PropString() => 'string',
        PropBool() => 'bool',
        PropNull() => 'null',
        PropList() => 'list',
        PropMap() => 'map',
      };
    }

    expect(describe(const PropInt(0)), 'int');
    expect(describe(const PropNull()), 'null');
    expect(describe(PropList(const [PropInt(1)])), 'list');
    expect(describe(PropMap(const {'k': PropInt(1)})), 'map');
  });
}
