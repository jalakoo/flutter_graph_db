import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:test/test.dart';

void main() {
  group('IdTranslationCache (plan §9.8)', () {
    test('put + lookup both directions', () {
      final c = IdTranslationCache();
      c.put('l-1', 'r-1');
      expect(c.remoteFor('l-1'), 'r-1');
      expect(c.logicalFor('r-1'), 'l-1');
      expect(c.remoteFor('missing'), isNull);
    });

    test('LRU evicts past maxEntries', () {
      final c = IdTranslationCache(maxEntries: 2);
      c.put('l-1', 'r-1');
      c.put('l-2', 'r-2');
      expect(c.length, 2);
      // Touch l-1 → l-2 becomes LRU.
      c.remoteFor('l-1');
      c.put('l-3', 'r-3');
      expect(c.remoteFor('l-1'), 'r-1');
      expect(c.remoteFor('l-2'), isNull);
      expect(c.remoteFor('l-3'), 'r-3');
    });

    test('re-putting an existing logical id with a new remote drops the old', () {
      final c = IdTranslationCache();
      c.put('l', 'r-1');
      c.put('l', 'r-2');
      expect(c.remoteFor('l'), 'r-2');
      expect(c.logicalFor('r-1'), isNull);
    });

    test('reset empties the cache', () {
      final c = IdTranslationCache();
      c.put('l', 'r');
      expect(c.length, 1);
      c.reset();
      expect(c.length, 0);
      expect(c.remoteFor('l'), isNull);
    });
  });
}
