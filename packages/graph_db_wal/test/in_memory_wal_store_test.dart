import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> xs) => Uint8List.fromList(xs);

Future<Uint8List> _readAll(WalStore store, {int fromOffset = 0}) async {
  final out = <int>[];
  await for (final chunk in store.read(fromOffset: fromOffset)) {
    out.addAll(chunk);
  }
  return Uint8List.fromList(out);
}

void main() {
  group('InMemoryWalStore', () {
    test('append + read round-trips byte-identical', () async {
      final store = InMemoryWalStore();
      await store.append(_bytes([1, 2, 3]), durability: Durability.group);
      await store.append(_bytes([4, 5]), durability: Durability.group);
      expect(await _readAll(store), _bytes([1, 2, 3, 4, 5]));
      expect(store.length, 5);
    });

    test('read from an offset skips earlier bytes', () async {
      final store = InMemoryWalStore();
      await store.append(_bytes([1, 2, 3]), durability: Durability.group);
      await store.append(_bytes([4, 5, 6]), durability: Durability.group);
      // Mid-chunk
      expect(await _readAll(store, fromOffset: 1), _bytes([2, 3, 4, 5, 6]));
      // At a chunk boundary
      expect(await _readAll(store, fromOffset: 3), _bytes([4, 5, 6]));
      // Past the end
      expect(await _readAll(store, fromOffset: 6), Uint8List(0));
    });

    test('append copies the buffer — caller mutation does not corrupt', () async {
      final store = InMemoryWalStore();
      final buf = _bytes([7, 7, 7]);
      await store.append(buf, durability: Durability.group);
      buf[0] = 99;
      expect(await _readAll(store), _bytes([7, 7, 7]));
    });

    test('truncate drops whole-chunk prefixes', () async {
      final store = InMemoryWalStore();
      await store.append(_bytes([1, 2, 3]), durability: Durability.group);
      await store.append(_bytes([4, 5]), durability: Durability.group);
      // Truncate < first chunk's size → nothing dropped.
      expect(await store.truncate(upToOffset: 2), 0);
      expect(await _readAll(store), _bytes([1, 2, 3, 4, 5]));
      // Truncate exactly at first chunk's end → first chunk gone.
      expect(await store.truncate(upToOffset: 3), 3);
      expect(await _readAll(store, fromOffset: 3), _bytes([4, 5]));
      // Reading before the truncated point throws.
      expect(
        () => _readAll(store, fromOffset: 0),
        throwsA(isA<StateError>()),
      );
    });

    test('sync is a no-op on RAM-only adapter', () async {
      final store = InMemoryWalStore();
      await store.append(_bytes([1]), durability: Durability.fsync);
      await store.sync(); // doesn't throw
      expect(store.length, 1);
    });

    test('close prevents further operations', () async {
      final store = InMemoryWalStore();
      await store.append(_bytes([1]), durability: Durability.group);
      await store.close();
      expect(
        () => store.append(_bytes([2]), durability: Durability.group),
        throwsA(isA<StateError>()),
      );
      expect(() => _readAll(store), throwsA(isA<StateError>()));
    });
  });
}
