import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

typedef _Harness = ({
  GraphDb db,
  InMemoryWalStore wal,
  InMemorySnapshotStore snap,
  CheckpointCoordinator coord,
});

Future<_Harness> _open({CheckpointPolicy policy = CheckpointPolicy.disabled}) async {
  final wal = InMemoryWalStore();
  final snap = InMemorySnapshotStore();
  final db = await openWalBackedGraphDb(store: wal);
  final coord = CheckpointCoordinator(
    db: db,
    walStore: wal,
    snapshotStore: snap,
    policy: policy,
  );
  coord.attach();
  return (db: db, wal: wal, snap: snap, coord: coord);
}

Future<int> _addNodes(GraphDb db, int n) async {
  final label = db.internLabel('N');
  for (var i = 0; i < n; i++) {
    await db.runTransaction((txn) => txn.addNode(labelIds: [label]));
  }
  return label;
}

/// Polls until the snapshot store has bytes (the async checkpoint phase
/// runs off the commit path).
Future<Uint8List?> _awaitSnapshot(InMemorySnapshotStore s) async {
  for (var i = 0; i < 1000; i++) {
    final b = await s.read();
    if (b != null) return b;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return null;
}

void main() {
  group('CheckpointCoordinator', () {
    test('checkpointNow writes a snapshot and truncates the WAL', () async {
      final h = await _open();
      await _addNodes(h.db, 3);
      expect(await h.snap.read(), isNull);
      expect(h.wal.length, greaterThan(0));

      await h.coord.checkpointNow();

      final bytes = await h.snap.read();
      expect(bytes, isNotNull, reason: 'a snapshot was persisted');
      expect(await h.wal.read().toList(), isEmpty,
          reason: 'WAL truncated up to the snapshot tip');
      final restored = GraphDb.fromState(decodeSnapshot(bytes!));
      expect(restored.labelScan(restored.internLabel('N')).length, 3);
      await h.db.close();
    });

    test('auto-checkpoint fires on the commit-count threshold', () async {
      final h = await _open(
        policy: const CheckpointPolicy(
          walBytesThreshold: null,
          commitCountThreshold: 3,
        ),
      );
      await _addNodes(h.db, 3); // the 3rd commit crosses the threshold
      expect(await _awaitSnapshot(h.snap), isNotNull,
          reason: 'auto-checkpoint should have fired');
      await h.db.close();
    });

    test('disabled policy never auto-checkpoints', () async {
      final h = await _open(policy: CheckpointPolicy.disabled);
      await _addNodes(h.db, 10);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await h.snap.read(), isNull);
      await h.db.close();
    });

    test('snapshot + truncated WAL recovers the full state', () async {
      final wal = InMemoryWalStore();
      final snap = InMemorySnapshotStore();
      final db = await openWalBackedGraphDb(store: wal);
      final coord = CheckpointCoordinator(
        db: db,
        walStore: wal,
        snapshotStore: snap,
        policy: CheckpointPolicy.disabled,
      );
      coord.attach();

      final label = db.internLabel('N');
      await db.runTransaction((txn) => txn.addNode(labelIds: [label]));
      await db.runTransaction((txn) => txn.addNode(labelIds: [label]));
      await coord.checkpointNow(); // snapshot covers 2 nodes; WAL truncated
      await db.runTransaction((txn) => txn.addNode(labelIds: [label])); // tail
      await db.close();

      // Restart from snapshot + the remaining (post-snapshot) WAL.
      wal.reopen();
      final snapBytes = await snap.read();
      final restored = await openWalBackedGraphDb(store: wal, snapshot: snapBytes);
      expect(restored.labelScan(restored.internLabel('N')).length, 3,
          reason: '2 from the snapshot + 1 replayed from the WAL tail');
      await restored.close();
    });
  });
}
