import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

void main() {
  group('Vid', () {
    test('isValid for normal values, invalid sentinel', () {
      expect(const Vid(0).isValid, true);
      expect(const Vid(1234).isValid, true);
      expect(const Vid(0xFFFFFFFE).isValid, true);
      expect(Vid.invalid.isValid, false);
    });
    test('equality is value-based', () {
      expect(const Vid(42), const Vid(42));
      expect(const Vid(42) == const Vid(43), false);
    });
  });

  group('Eid', () {
    test('isValid for normal values, invalid sentinel', () {
      expect(const Eid(0).isValid, true);
      expect(Eid.invalid.isValid, false);
    });
  });
}
