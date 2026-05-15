import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

void main() {
  group('PropertyStore — type-locked columns', () {
    test('first write infers the column type', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.setInt(7, 1, 42);
      expect(ps.columnType(1), ColumnType.int_);
      expect(ps.getInt(7, 1), 42);
    });

    test('subsequent writes of the same type update the slot', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.setInt(7, 1, 42);
      ps.setInt(7, 1, 99);
      expect(ps.getInt(7, 1), 99);
    });

    test('mismatched type raises ConstraintViolation', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.setInt(7, 1, 42);
      expect(
        () => ps.setDouble(7, 1, 1.5),
        throwsA(isA<ConstraintViolation>()),
      );
      expect(
        () => ps.setBool(8, 1, true),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('dropColumn permits a type change on the next write', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.setInt(7, 1, 42);
      ps.dropColumn(1);
      ps.setDouble(7, 1, 1.5);
      expect(ps.columnType(1), ColumnType.double_);
      expect(ps.getDouble(7, 1), 1.5);
    });

    test('createColumn pre-declares a column; redeclare differing type fails',
        () {
      final ps = PropertyStore(vidSpace: 100);
      ps.createColumn(1, ColumnType.bool_);
      ps.setBool(7, 1, true);
      expect(ps.getBool(7, 1), true);
      // Same type re-declare is a no-op.
      ps.createColumn(1, ColumnType.bool_);
      // Different type re-declare without dropping first throws.
      expect(
        () => ps.createColumn(1, ColumnType.int_),
        throwsA(isA<ConstraintViolation>()),
      );
    });
  });

  group('PropertyStore — null vs missing', () {
    test('has() is false for unset key', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.setInt(7, 1, 42);
      expect(ps.has(7, 1), true);
      expect(ps.has(8, 1), false);
    });

    test('explicit setNull marks the slot as null, has() is still true', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.createColumn(1, ColumnType.int_);
      ps.setNull(7, 1);
      expect(ps.has(7, 1), true);
      expect(ps.isNull(7, 1), true);
    });

    test('setNull on an undeclared key raises ConstraintViolation', () {
      final ps = PropertyStore(vidSpace: 100);
      expect(
        () => ps.setNull(7, 1),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('a typed write clears the isNull bit on the slot', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.createColumn(1, ColumnType.int_);
      ps.setNull(7, 1);
      expect(ps.isNull(7, 1), true);
      ps.setInt(7, 1, 5);
      expect(ps.isNull(7, 1), false);
      expect(ps.getInt(7, 1), 5);
    });

    test('remove() makes the key not-set; has() is false', () {
      final ps = PropertyStore(vidSpace: 100);
      ps.setInt(7, 1, 42);
      ps.remove(7, 1);
      expect(ps.has(7, 1), false);
      expect(ps.isNull(7, 1), false);
    });
  });

  group('PropertyStore — growth + boundary reads', () {
    test('column grows past initial capacity (16) without losing values', () {
      final ps = PropertyStore(vidSpace: 200);
      for (var v = 0; v < 100; v++) {
        ps.setInt(v, 1, v * 10);
      }
      for (var v = 0; v < 100; v++) {
        expect(ps.getInt(v, 1), v * 10);
      }
    });

    test('getBoxed returns the right PropValue subclass per column type',
        () {
      final ps = PropertyStore(vidSpace: 10);
      ps.setInt(0, 1, 7);
      ps.setDouble(0, 2, 1.5);
      ps.setBool(0, 3, true);
      ps.createColumn(4, ColumnType.int_);
      ps.setNull(0, 4);
      expect(ps.getBoxed(0, 1), const PropInt(7));
      expect(ps.getBoxed(0, 2), const PropDouble(1.5));
      expect(ps.getBoxed(0, 3), const PropBool(true));
      expect(ps.getBoxed(0, 4), const PropNull());
      expect(ps.getBoxed(0, 99), null); // no such column
      expect(ps.getBoxed(9, 1), null);  // column exists, not set on vid 9
    });
  });
}
