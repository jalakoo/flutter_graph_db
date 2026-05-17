/// Browser-side tests for the IndexedDB-backed [WalStore]
/// (plan §11 / §14 Phase 8).
///
/// **Run with:** `dart test -p chrome` (or `firefox`). On the VM these
/// tests are skipped — the IndexedDB API only exists in browsers.
///
/// The native `InMemoryWalStore` + io adapter are the validated stores
/// for v1; this file is the safety net once browser-side CI is wired in.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/indexeddb_wal_store.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> xs) => Uint8List.fromList(xs);

Future<Uint8List> _readAll(IndexedDbWalStore store, {int fromOffset = 0}) async {
  final out = <int>[];
  await for (final chunk in store.read(fromOffset: fromOffset)) {
    out.addAll(chunk);
  }
  return Uint8List.fromList(out);
}

/// Each test uses a unique DB name + deletes it on teardown so suites
/// run in any order on the same browser profile.
Future<IndexedDbWalStore> _fresh(String name) async {
  final s = await openIndexedDbWalStore(dbName: name);
  // Defensive: a previous run may have left state behind.
  await s.deleteDatabase();
  return openIndexedDbWalStore(dbName: name);
}

void main() {
  group('IndexedDbWalStore', () {
    test('append + read round-trips byte-identical', () async {
      final store = await _fresh('idb_wal_test_1');
      try {
        await store.append(_bytes([1, 2, 3]), durability: Durability.fsync);
        await store.append(_bytes([4, 5]), durability: Durability.fsync);
        expect(await _readAll(store), _bytes([1, 2, 3, 4, 5]));
        expect(store.length, 5);
      } finally {
        await store.deleteDatabase();
      }
    });

    test('read from an offset skips earlier bytes', () async {
      final store = await _fresh('idb_wal_test_2');
      try {
        await store.append(_bytes([1, 2, 3]), durability: Durability.fsync);
        await store.append(_bytes([4, 5, 6]), durability: Durability.fsync);
        expect(await _readAll(store, fromOffset: 1), _bytes([2, 3, 4, 5, 6]));
        expect(await _readAll(store, fromOffset: 3), _bytes([4, 5, 6]));
        expect(await _readAll(store, fromOffset: 6), Uint8List(0));
      } finally {
        await store.deleteDatabase();
      }
    });

    test('persists across reopens', () async {
      const name = 'idb_wal_test_3';
      final s1 = await _fresh(name);
      await s1.append(_bytes([10, 20, 30]), durability: Durability.fsync);
      await s1.close();
      final s2 = await openIndexedDbWalStore(dbName: name);
      try {
        expect(s2.length, 3);
        expect(await _readAll(s2), _bytes([10, 20, 30]));
      } finally {
        await s2.deleteDatabase();
      }
    });

    test('truncate drops chunks below the boundary', () async {
      final store = await _fresh('idb_wal_test_4');
      try {
        await store.append(_bytes([1, 2, 3]), durability: Durability.fsync);
        await store.append(_bytes([4, 5]), durability: Durability.fsync);
        // Drop the first chunk only.
        final retained = await store.truncate(upToOffset: 3);
        expect(retained, 3);
        // Reads from before the boundary silently advance.
        expect(await _readAll(store, fromOffset: 0), _bytes([4, 5]));
        expect(await _readAll(store, fromOffset: 3), _bytes([4, 5]));
      } finally {
        await store.deleteDatabase();
      }
    });

    test('close prevents further operations', () async {
      final store = await _fresh('idb_wal_test_5');
      await store.append(_bytes([7]), durability: Durability.fsync);
      await store.close();
      expect(
        () => store.append(_bytes([8]), durability: Durability.fsync),
        throwsA(isA<StateError>()),
      );
      // Cleanup separately — we already closed the handle.
      final s2 = await openIndexedDbWalStore(dbName: 'idb_wal_test_5');
      await s2.deleteDatabase();
    });
  });
}
