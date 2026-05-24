import 'dart:io';

import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:graph_db_wal/io_wal_store.dart';
import 'package:test/test.dart';

Future<void> _settle(Future<bool> Function() done) async {
  for (var i = 0; i < 1000; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('open_at_path_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('data persists across a close + reopen at the same path', () async {
    final path = '${tmp.path}/graph';
    final h1 = await openGraphDbAtPath(
      path,
      checkpointPolicy: CheckpointPolicy.disabled,
    );
    final label = h1.db.internLabel('N');
    await h1.db.runTransaction((txn) => txn.addNode(labelIds: [label]));
    await h1.db.runTransaction((txn) => txn.addNode(labelIds: [label]));
    await h1.close();

    final h2 = await openGraphDbAtPath(
      path,
      checkpointPolicy: CheckpointPolicy.disabled,
    );
    expect(h2.db.labelScan(h2.db.internLabel('N')).length, 2);
    await h2.close();
  });

  test('auto-checkpoint compacts the WAL and still recovers full state',
      () async {
    final path = '${tmp.path}/graph';
    final h1 = await openGraphDbAtPath(
      path,
      checkpointPolicy: const CheckpointPolicy(
        walBytesThreshold: null,
        commitCountThreshold: 2,
      ),
    );
    final label = h1.db.internLabel('N');
    for (var i = 0; i < 5; i++) {
      await h1.db.runTransaction((txn) => txn.addNode(labelIds: [label]));
    }
    await _settle(() => File('$path.snapshot').exists());
    await h1.close(); // drains the in-flight checkpoint

    expect(await File('$path.snapshot').exists(), isTrue,
        reason: 'auto-checkpoint wrote a snapshot');

    final h2 = await openGraphDbAtPath(path);
    expect(h2.db.labelScan(h2.db.internLabel('N')).length, 5,
        reason: 'snapshot + WAL tail recover every node');
    await h2.close();
  });

  test('checkpointNow before close, then full recovery', () async {
    final path = '${tmp.path}/graph';
    final h1 = await openGraphDbAtPath(
      path,
      checkpointPolicy: CheckpointPolicy.disabled,
    );
    final label = h1.db.internLabel('N');
    await h1.db.runTransaction((txn) => txn.addNode(labelIds: [label]));
    await h1.checkpointNow(); // snapshot covers 1 node, WAL truncated
    await h1.db.runTransaction((txn) => txn.addNode(labelIds: [label]));
    await h1.close();

    final h2 = await openGraphDbAtPath(path);
    expect(h2.db.labelScan(h2.db.internLabel('N')).length, 2);
    await h2.close();
  });
}
