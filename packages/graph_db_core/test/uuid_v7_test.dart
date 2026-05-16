import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

void main() {
  test('newUuidV7 returns a 36-char v7 string', () {
    final id = newUuidV7();
    expect(id.length, 36);
    // 8-4-4-4-12 dashes
    expect(id[8], '-');
    expect(id[13], '-');
    expect(id[18], '-');
    expect(id[23], '-');
    // Version nibble at index 14 = '7'
    expect(id[14], '7');
  });

  test('newUuidV7 across millisecond boundaries is strictly ascending', () {
    // Generate batches with explicit ms gaps; per-ms ordering of the
    // random sub-ms bits is implementation-defined and not asserted.
    final maxes = <String>[];
    final mins = <String>[];
    for (var i = 0; i < 4; i++) {
      final batch = List.generate(8, (_) => newUuidV7())..sort();
      maxes.add(batch.last);
      mins.add(batch.first);
      // Burn at least 2ms so the timestamp prefix advances.
      final until = DateTime.now().add(const Duration(milliseconds: 2));
      while (DateTime.now().isBefore(until)) {}
    }
    for (var i = 1; i < maxes.length; i++) {
      expect(mins[i].compareTo(maxes[i - 1]), greaterThan(0),
          reason: 'batch $i should sort strictly after batch ${i - 1}');
    }
  });

  test('SequentialIdGenerator produces prefix-N strings in order', () {
    final g = SequentialIdGenerator(prefix: 'x-', start: 100);
    expect(g.next(), 'x-100');
    expect(g.next(), 'x-101');
    expect(g.next(), 'x-102');
  });

  test('UuidV7Generator wraps newUuidV7', () {
    final g = const UuidV7Generator();
    final id = g.next();
    expect(id.length, 36);
    expect(id[14], '7');
  });
}
