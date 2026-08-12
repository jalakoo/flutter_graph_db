@TestOn('vm')
library;

import 'dart:io';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_sync/graph_db_sync.dart';
import 'package:graph_db_sync/io_sync_state_store.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

import 'sync_engine_test.dart' show FakeRemoteClient;

/// Per-target sync progress must survive a restart.
///
/// Regression: the high-water mark lived only in memory, so a restart
/// re-shipped the entire retained WAL to every target.

/// Flattens [FakeRemoteClient.importBatches] — these tests care about how
/// much was shipped in total, not how it was chunked.
extension on FakeRemoteClient {
  List<ImportOp> get received => importBatches.expand((b) => b).toList();
  int get importCalls => importBatches.length;
}

Future<GraphDb> _seedGraph(WalStore store) async {
  final db = await openWalBackedGraphDb(store: store);
  await db.runTransaction((t) {
    final a = t.addNodeNamed(labels: const ['P'], props: {
      'name': const PropString('Ada'),
    });
    final b = t.addNodeNamed(labels: const ['P'], props: {
      'name': const PropString('Bob'),
    });
    t.addEdgeNamed(src: a, dst: b, type: 'KNOWS');
  }, durability: Durability.fsync);
  return db;
}

void main() {
  test('without a state store, a restart re-ships everything', () async {
    final store = InMemoryWalStore();
    final db = await _seedGraph(store);

    final first = FakeRemoteClient();
    await SyncEngine(
      db: db,
      walStore: store,
      targets: [SyncTarget(name: 't', client: first)],
    ).syncOnce();
    expect(first.received, isNotEmpty);

    // Fresh engine, fresh target — the in-memory HWM is gone.
    final second = FakeRemoteClient();
    await SyncEngine(
      db: db,
      walStore: store,
      targets: [SyncTarget(name: 't', client: second)],
    ).syncOnce();
    expect(second.received.length, first.received.length,
        reason: 'this is the behaviour a state store exists to fix');
  });

  test('with a state store, a restart ships nothing new', () async {
    final store = InMemoryWalStore();
    final db = await _seedGraph(store);
    final stateStore = InMemorySyncStateStore();

    final first = FakeRemoteClient();
    final reports = await SyncEngine(
      db: db,
      walStore: store,
      targets: [SyncTarget(name: 't', client: first)],
      stateStore: stateStore,
    ).syncOnce();
    expect(first.received, isNotEmpty);
    expect(reports.single.newHwm, greaterThan(reports.single.previousHwm));

    final second = FakeRemoteClient();
    final resumed = SyncEngine(
      db: db,
      walStore: store,
      targets: [SyncTarget(name: 't', client: second)],
      stateStore: stateStore,
    );
    await resumed.restore();
    final secondReports = await resumed.syncOnce();

    expect(second.received, isEmpty, reason: 'HWM was restored');
    expect(second.importCalls, 0);
    expect(secondReports.single.previousHwm, reports.single.newHwm);
  });

  test('a restored target picks up only ops added since', () async {
    final store = InMemoryWalStore();
    final db = await _seedGraph(store);
    final stateStore = InMemorySyncStateStore();

    final first = FakeRemoteClient();
    await SyncEngine(
      db: db,
      walStore: store,
      targets: [SyncTarget(name: 't', client: first)],
      stateStore: stateStore,
    ).syncOnce();
    final shippedFirst = first.received.length;

    // One more node lands after the first sync.
    await db.runTransaction(
        (t) => t.addNodeNamed(labels: const ['P'], props: {
              'name': const PropString('Cy'),
            }),
        durability: Durability.fsync);

    final second = FakeRemoteClient();
    final resumed = SyncEngine(
      db: db,
      walStore: store,
      targets: [SyncTarget(name: 't', client: second)],
      stateStore: stateStore,
    );
    await resumed.restore();
    await resumed.syncOnce();

    expect(shippedFirst, greaterThan(0));
    expect(second.received.length, 1, reason: 'only the new node');
  });

  test('an unknown target keeps its defaults', () async {
    final store = InMemoryWalStore();
    final db = await _seedGraph(store);
    final stateStore = InMemorySyncStateStore();
    await stateStore.write(
        'other', const SyncTargetState(hwm: 999, seeded: true));

    final client = FakeRemoteClient();
    final target = SyncTarget(name: 'fresh', client: client);
    final engine = SyncEngine(
      db: db,
      walStore: store,
      targets: [target],
      stateStore: stateStore,
    );
    await engine.restore();

    expect(target.hwm, -1, reason: 'no persisted entry for this name');
    await engine.syncOnce();
    expect(client.received, isNotEmpty);
  });

  test('per-target state is kept separate', () async {
    final store = InMemoryWalStore();
    final db = await _seedGraph(store);
    final stateStore = InMemorySyncStateStore();

    final a = FakeRemoteClient();
    final b = FakeRemoteClient();
    await SyncEngine(
      db: db,
      walStore: store,
      targets: [
        SyncTarget(name: 'a', client: a),
        SyncTarget(name: 'b', client: b),
      ],
      stateStore: stateStore,
    ).syncOnce();

    final states = await stateStore.readAll();
    expect(states.keys, containsAll(['a', 'b']));
    expect(states['a']!.hwm, states['b']!.hwm);
  });

  group('IoSyncStateStore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sync_state');
    });
    tearDown(() => dir.delete(recursive: true));

    test('round-trips across a reopen', () async {
      final path = '${dir.path}/sync.json';
      var s = await IoSyncStateStore.open(path);
      await s.write('t', const SyncTargetState(hwm: 42, seeded: true));
      await s.close();

      s = await IoSyncStateStore.open(path);
      final states = await s.readAll();
      expect(states['t'], const SyncTargetState(hwm: 42, seeded: true));
      await s.close();
    });

    test('reads empty when the file does not exist', () async {
      final s = await IoSyncStateStore.open('${dir.path}/missing.json');
      expect(await s.readAll(), isEmpty);
      await s.close();
    });

    test('delete removes one target and keeps the rest', () async {
      final path = '${dir.path}/sync.json';
      var s = await IoSyncStateStore.open(path);
      await s.write('a', const SyncTargetState(hwm: 1, seeded: true));
      await s.write('b', const SyncTargetState(hwm: 2, seeded: true));
      await s.delete('a');
      await s.close();

      s = await IoSyncStateStore.open(path);
      final states = await s.readAll();
      expect(states.keys, ['b']);
      await s.close();
    });

    test('leaves no temp file behind', () async {
      final s = await IoSyncStateStore.open('${dir.path}/sync.json');
      await s.write('t', const SyncTargetState(hwm: 1, seeded: true));
      await s.close();
      final names = dir.listSync().map((e) => e.path).toList();
      expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
    });

    test('drives a real resume', () async {
      final store = InMemoryWalStore();
      final db = await _seedGraph(store);
      final path = '${dir.path}/sync.json';

      var stateStore = await IoSyncStateStore.open(path);
      final first = FakeRemoteClient();
      await SyncEngine(
        db: db,
        walStore: store,
        targets: [SyncTarget(name: 't', client: first)],
        stateStore: stateStore,
      ).syncOnce();
      await stateStore.close();
      expect(first.received, isNotEmpty);

      stateStore = await IoSyncStateStore.open(path);
      final second = FakeRemoteClient();
      final resumed = SyncEngine(
        db: db,
        walStore: store,
        targets: [SyncTarget(name: 't', client: second)],
        stateStore: stateStore,
      );
      await resumed.restore();
      await resumed.syncOnce();
      expect(second.received, isEmpty);
      await stateStore.close();
    });
  });
}
