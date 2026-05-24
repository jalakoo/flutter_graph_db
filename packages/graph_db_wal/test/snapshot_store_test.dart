import 'dart:io';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:graph_db_wal/io_wal_store.dart';
import 'package:test/test.dart';

/// Builds a small graph, merges, and returns its encoded snapshot bytes
/// plus the source db (so a test can compare the restored state).
Future<({Uint8List bytes, int personLabel})> _encodedFixture() async {
  final db = await openWalBackedGraphDb(store: InMemoryWalStore());
  final person = db.internLabel('Person');
  final name = db.internPropKey('name');
  await db.runTransaction((txn) {
    txn.addNode(labelIds: [person], props: {name: const PropString('Ada')});
    txn.addNode(labelIds: [person], props: {name: const PropString('Bob')});
  });
  db.state.mergeNow(); // encodeSnapshot requires an empty overlay
  final snap = encodeSnapshot(db.state);
  await db.close();
  return (bytes: snap.bytes, personLabel: person);
}

/// Exercises the [SnapshotStore] contract against [make] (called once
/// per test for a fresh, empty store).
void runStoreContract(String name, Future<SnapshotStore> Function() make) {
  group('$name — SnapshotStore contract', () {
    test('read() is null before anything is written', () async {
      final store = await make();
      expect(await store.read(), isNull);
      await store.close();
    });

    test('write() then read() round-trips the exact bytes', () async {
      final store = await make();
      final bytes = Uint8List.fromList([1, 2, 3, 4, 250, 0, 99]);
      await store.write(bytes);
      expect(await store.read(), orderedEquals(bytes));
      await store.close();
    });

    test('write() atomically replaces the previous snapshot', () async {
      final store = await make();
      await store.write(Uint8List.fromList([1, 1, 1]));
      await store.write(Uint8List.fromList([2, 2, 2, 2]));
      expect(await store.read(), orderedEquals([2, 2, 2, 2]));
      await store.close();
    });

    test('delete() clears the snapshot and is idempotent', () async {
      final store = await make();
      await store.write(Uint8List.fromList([9, 9]));
      await store.delete();
      expect(await store.read(), isNull);
      await store.delete(); // no-op, must not throw
      await store.close();
    });

    test('operations throw after close()', () async {
      final store = await make();
      await store.close();
      expect(() => store.read(), throwsStateError);
      expect(() => store.write(Uint8List(1)), throwsStateError);
    });

    test('encode -> store -> load -> decode restores the graph', () async {
      final store = await make();
      final fix = await _encodedFixture();
      await store.write(fix.bytes);

      final loaded = await store.read();
      expect(loaded, isNotNull);
      final restored = GraphDb.fromState(decodeSnapshot(loaded!));
      expect(restored.labelScan(fix.personLabel).length, 2,
          reason: 'both Person nodes survive the snapshot round-trip');
      await store.close();
    });
  });
}

void main() {
  runStoreContract('InMemorySnapshotStore', () async => InMemorySnapshotStore());

  group('IoSnapshotStore', () {
    late Directory tmp;
    var counter = 0;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('snap_store_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    runStoreContract(
      'IoSnapshotStore',
      () => IoSnapshotStore.open('${tmp.path}/graph_${counter++}.snapshot'),
    );

    test('survives reopen at the same path', () async {
      final path = '${tmp.path}/persist.snapshot';
      final a = await IoSnapshotStore.open(path);
      await a.write(Uint8List.fromList([7, 7, 7]));
      await a.close();

      final b = await IoSnapshotStore.open(path);
      expect(await b.read(), orderedEquals([7, 7, 7]));
      await b.close();
    });
  });
}
