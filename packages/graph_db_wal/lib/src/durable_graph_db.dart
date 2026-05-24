import 'package:graph_db_core/graph_db_core.dart';

import 'checkpoint.dart';
import 'codec/wal_codec.dart';
import 'io_snapshot_store.dart';
import 'io_wal_store.dart';
import 'recovery.dart';
import 'snapshot_store.dart';

/// A ready-to-use durable [GraphDb] plus the resources behind it.
///
/// Returned by [openGraphDbAtPath]. Use [db] for all reads and writes;
/// call [checkpointNow] at safe lifecycle points (e.g. app
/// backgrounding) and [close] on shutdown.
class DurableGraphDb {
  /// The engine. All reads and `runTransaction` calls go here.
  final GraphDb db;

  /// The auto-checkpoint coordinator wired to [db].
  final CheckpointCoordinator checkpoint;

  final SnapshotStore _snapshotStore;

  DurableGraphDb._(this.db, this.checkpoint, this._snapshotStore);

  /// Forces a checkpoint now (write a snapshot, truncate the WAL),
  /// regardless of the policy. Handy on app backgrounding to bound
  /// restart time. See [CheckpointCoordinator.checkpointNow].
  Future<void> checkpointNow() => checkpoint.checkpointNow();

  /// Closes everything cleanly: stops auto-checkpointing, waits out any
  /// in-flight checkpoint, flushes + closes the WAL (via the engine),
  /// then closes the snapshot store. Idempotent via [GraphDb.close].
  Future<void> close() async {
    checkpoint.detach();
    await checkpoint.drain();
    await db.close(); // flushes + closes the WalStore through the sink
    await _snapshotStore.close();
  }
}

/// One-call durable open (native only — uses `dart:io`).
///
/// Wires an [IoWalStore] at [path] and an [IoSnapshotStore] at
/// `<path>.snapshot`, restores the latest snapshot, replays the WAL tail
/// on top of it, and — unless [checkpointPolicy] is
/// [CheckpointPolicy.disabled] — attaches a [CheckpointCoordinator] so
/// the WAL compacts itself as it grows. Creates the file (and parent
/// directory) if absent.
///
/// This collapses the previous two-step dance (`IoWalStore.open` →
/// `openWalBackedGraphDb`, plus a manual snapshot-file read) into one
/// call. The two-step API stays available for advanced wiring.
///
/// ```dart
/// import 'package:graph_db_wal/io_wal_store.dart';
///
/// final handle = await openGraphDbAtPath('${dir.path}/graph');
/// await handle.db.runTransaction((txn) => /* ... */);
/// await handle.checkpointNow(); // e.g. on backgrounding
/// await handle.close();
/// ```
Future<DurableGraphDb> openGraphDbAtPath(
  String path, {
  WalCodec codec = const WalCodec(),
  CheckpointPolicy checkpointPolicy = const CheckpointPolicy(),
}) async {
  final walStore = await IoWalStore.open(path);
  final snapshotStore = await IoSnapshotStore.open('$path.snapshot');

  // Restore the latest snapshot (if any), then replay the WAL on top.
  // recoverInto's replay is idempotent, so a snapshot left ahead of an
  // un-truncated WAL (crash between checkpoint's write and truncate)
  // still recovers to the correct state.
  final snapshot = await snapshotStore.read();
  final db = await openWalBackedGraphDb(
    store: walStore,
    codec: codec,
    snapshot: snapshot,
  );

  final coordinator = CheckpointCoordinator(
    db: db,
    walStore: walStore,
    snapshotStore: snapshotStore,
    policy: checkpointPolicy,
  )..attach();

  return DurableGraphDb._(db, coordinator, snapshotStore);
}
