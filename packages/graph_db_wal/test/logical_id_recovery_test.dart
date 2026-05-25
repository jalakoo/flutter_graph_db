import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

/// The built-in logical-id index is maintained in applyAddNode, so it
/// rebuilds for free when the WAL replays on recovery (no snapshot
/// needed), and is also restored from a snapshot.
void main() {
  test('logical-id index rebuilds from the WAL on recovery', () async {
    final store = InMemoryWalStore();
    final db = await openWalBackedGraphDb(store: store);
    final n = db.internLabel('N');
    final a = await db.runTransaction(
        (txn) => txn.addNode(labelIds: [n], logicalId: 'ext-a'));
    await db.close();

    store.reopen();
    final db2 = await openWalBackedGraphDb(store: store);
    expect(db2.nodeByLogicalId('ext-a')?.value, a.value);
    expect(db2.getNodeLogicalId(a), 'ext-a');
    await db2.close();
  });

  test('logical-id index survives snapshot + truncated WAL', () async {
    final wal = InMemoryWalStore();
    final snaps = InMemorySnapshotStore();
    final db = await openWalBackedGraphDb(store: wal, snapshotStore: snaps);
    final n = db.internLabel('N');
    final a = await db.runTransaction(
        (txn) => txn.addNode(labelIds: [n], logicalId: 'ext-a'));
    final coord = CheckpointCoordinator(
        db: db, walStore: wal, snapshotStore: snaps);
    await coord.checkpointNow(); // snapshot holds 'ext-a'; WAL truncated
    await db.close();

    wal.reopen();
    final db2 = await openWalBackedGraphDb(store: wal, snapshotStore: snaps);
    expect(db2.nodeByLogicalId('ext-a')?.value, a.value);
    await db2.close();
  });
}
