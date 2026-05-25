import 'dart:typed_data';

import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

Future<Uint8List?> _awaitSnapshot(InMemorySnapshotStore s) async {
  for (var i = 0; i < 1000; i++) {
    final b = await s.read();
    if (b != null) return b;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return null;
}

void main() {
  test('CheckpointPolicy.auto / manual set the expected thresholds', () {
    const p = CheckpointPolicy.auto(maxWalBytes: 1 << 20, everyCommits: 5);
    expect(p.walBytesThreshold, 1 << 20);
    expect(p.commitCountThreshold, 5);
    expect(p.isEnabled, isTrue);
    expect(CheckpointPolicy.manual.isEnabled, isFalse);
  });

  test('openWalBackedGraphDb(snapshotStore:, checkpoint:) auto-checkpoints '
      'and reloads the snapshot on reopen', () async {
    final wal = InMemoryWalStore();
    final snaps = InMemorySnapshotStore();
    final db = await openWalBackedGraphDb(
      store: wal,
      snapshotStore: snaps,
      checkpoint:
          const CheckpointPolicy.auto(maxWalBytes: 1 << 20, everyCommits: 2),
    );
    final label = db.internLabel('N');
    for (var i = 0; i < 3; i++) {
      await db.runTransaction((txn) => txn.addNode(labelIds: [label]));
    }
    expect(await _awaitSnapshot(snaps), isNotNull,
        reason: 'auto-checkpoint should have written a snapshot');
    await Future<void>.delayed(const Duration(milliseconds: 50)); // let truncate settle
    await db.close();

    // Reopen from the SAME stores — the snapshot loads automatically (no
    // explicit snapshot: bytes), then the WAL tail replays. Idempotent
    // replay means it recovers the full state regardless of whether the
    // checkpoint's truncate had completed.
    wal.reopen();
    final db2 = await openWalBackedGraphDb(store: wal, snapshotStore: snaps);
    expect(db2.labelScan(db2.internLabel('N')).length, 3);
    await db2.close();
  });
}
