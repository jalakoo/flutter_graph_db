import 'dart:async';

import 'package:graph_db_core/graph_db_core.dart';

import 'snapshot_store.dart';
import 'wal_store.dart';

/// When an automatic checkpoint fires.
///
/// A checkpoint = write a fresh snapshot to the [SnapshotStore], then
/// truncate the WAL up to that snapshot's tip. Either threshold (or
/// both) can be set; a `null` threshold disables that trigger.
class CheckpointPolicy {
  /// Checkpoint once the WAL has grown by at least this many bytes since
  /// the last checkpoint. `null` disables the byte trigger.
  final int? walBytesThreshold;

  /// Checkpoint once this many commits have landed since the last
  /// checkpoint. `null` disables the commit-count trigger.
  final int? commitCountThreshold;

  const CheckpointPolicy({
    this.walBytesThreshold = 8 * 1024 * 1024, // 8 MiB
    this.commitCountThreshold,
  });

  /// Auto-checkpoint on a WAL-size (and/or commit-count) threshold.
  /// Reads naturally at the call site:
  /// `checkpoint: CheckpointPolicy.auto(maxWalBytes: 1 << 20)`.
  const CheckpointPolicy.auto({
    int maxWalBytes = 8 * 1024 * 1024,
    int? everyCommits,
  })  : walBytesThreshold = maxWalBytes,
        commitCountThreshold = everyCommits;

  /// Auto-checkpoint off — only manual [CheckpointCoordinator.checkpointNow]
  /// (e.g. on app close). Alias: [disabled].
  static const CheckpointPolicy manual =
      CheckpointPolicy(walBytesThreshold: null);

  /// Auto-checkpoint off — only manual [CheckpointCoordinator.checkpointNow].
  static const CheckpointPolicy disabled = manual;

  bool get isEnabled =>
      walBytesThreshold != null || commitCountThreshold != null;
}

/// Drives automatic WAL checkpointing for a WAL-backed [GraphDb].
///
/// [attach] registers a post-commit hook on the engine. After each
/// commit it checks [policy]; when a threshold is crossed it:
///   1. **synchronously** merges the overlay, encodes a snapshot, and
///      captures the WAL tip — atomic w.r.t. the engine's single writer,
///      so concurrent commits can't shift the truncate point;
///   2. **asynchronously** writes the snapshot durably, then truncates
///      the WAL up to the captured tip.
///
/// The snapshot is made durable *before* the WAL is truncated, so a
/// crash mid-checkpoint never loses committed data — recovery falls back
/// to the (untruncated) WAL.
///
/// The async phase runs off the commit path, so writes aren't blocked by
/// snapshot I/O. The synchronous encode does run on the triggering
/// commit; for very large graphs that cost is the v1 trade-off (a
/// background-encode path is a future enhancement).
class CheckpointCoordinator {
  final GraphDb db;
  final WalStore walStore;
  final SnapshotStore snapshotStore;
  final CheckpointPolicy policy;

  /// Reports errors from the asynchronous checkpoint phase (which can't
  /// be surfaced to a caller). If null, async errors are swallowed.
  final void Function(Object error, StackTrace stackTrace)? onError;

  int _commitsSinceCheckpoint = 0;
  int _walBytesAtLastCheckpoint = 0;
  bool _busy = false;
  Future<void> _current = Future<void>.value();
  bool _attached = false;

  CheckpointCoordinator({
    required this.db,
    required this.walStore,
    required this.snapshotStore,
    this.policy = const CheckpointPolicy(),
    this.onError,
  });

  /// Registers the post-commit hook. No-op if already attached or if the
  /// policy is disabled (manual checkpoints still work via [checkpointNow]).
  void attach() {
    if (_attached) return;
    _attached = true;
    _walBytesAtLastCheckpoint = walStore.length;
    if (policy.isEnabled) db.afterCommit = _onCommit;
  }

  /// Unregisters the hook. Pending async checkpoints still complete.
  void detach() {
    if (identical(db.afterCommit, _onCommit)) db.afterCommit = null;
    _attached = false;
  }

  /// True while an async checkpoint write/truncate is in flight.
  bool get isCheckpointing => _busy;

  void _onCommit() {
    _commitsSinceCheckpoint++;
    if (_busy) return; // one already running — fold this commit into the next
    if (!_shouldCheckpoint()) return;
    _current = _checkpoint();
    // Auto path can't propagate errors to a caller — route to onError.
    unawaited(_current.then((_) {}, onError: (Object e, StackTrace st) {
      onError?.call(e, st);
    }));
  }

  bool _shouldCheckpoint() {
    final commits = policy.commitCountThreshold;
    if (commits != null && _commitsSinceCheckpoint >= commits) return true;
    final bytes = policy.walBytesThreshold;
    if (bytes != null &&
        walStore.length - _walBytesAtLastCheckpoint >= bytes) {
      return true;
    }
    return false;
  }

  /// Forces a checkpoint immediately, regardless of [policy] — e.g. on
  /// app backgrounding. Call when no write is in flight (single-writer).
  /// If an auto-checkpoint is already running, waits for it, then runs a
  /// fresh one.
  Future<void> checkpointNow() async {
    await drain();
    _current = _checkpoint();
    await _current;
  }

  /// Waits for any in-flight async checkpoint to finish, without
  /// starting a new one. Call before closing the underlying stores so a
  /// checkpoint's truncate can't race a store close.
  Future<void> drain() async {
    while (_busy) {
      await _current.then((_) {}, onError: (_, __) {});
    }
  }

  Future<void> _checkpoint() async {
    _busy = true;
    try {
      // --- synchronous, atomic capture (no await before the offset) ---
      db.state.mergeNow(); // encodeSnapshot requires an empty overlay
      final bytes = encodeSnapshot(db.state).bytes;
      final truncateOffset = walStore.length;
      _commitsSinceCheckpoint = 0;
      _walBytesAtLastCheckpoint = truncateOffset;

      // --- async: durable snapshot BEFORE dropping the WAL it replaces ---
      await snapshotStore.write(bytes);
      await walStore.truncate(upToOffset: truncateOffset);
      _walBytesAtLastCheckpoint = walStore.length;
    } finally {
      _busy = false;
    }
  }
}
