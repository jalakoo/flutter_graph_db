/// WAL recovery.
///
/// Reads a [WalStore], filters to only those `txnId`s that have a
/// matching [CommitTxn], and replays the surviving ops through the
/// applicator in `recovery: true` mode.
///
/// **Two-pass, streaming.** Pass 1 scans for committed `txnId`s; pass 2
/// re-reads and applies. Only the committed-txnId set is held in memory,
/// so peak usage tracks the number of transactions rather than the size
/// of the WAL. (It used to buffer every decoded op, which doubled the
/// cost of a large recovery on top of the state being rebuilt.) The
/// trade is reading the log twice; a one-pass scan with bounded lookahead
/// is the natural next refinement.
library;

import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
// Internal cross-package reach into graph_db_core's applicator. The
// applicator is intentionally not on the public surface (only
// `GraphDb.runTransaction` is) — WAL recovery is the one legitimate
// alt path, so it imports directly from `src/`.
// ignore: implementation_imports
import 'package:graph_db_core/src/applicator.dart';

import 'checkpoint.dart';
import 'codec/wal_codec.dart';
import 'snapshot_store.dart';
import 'wal_reader.dart';
import 'wal_store.dart';
import 'wal_writer.dart';

/// Recovers a [MutableGraphState] from [store] by replaying every
/// **committed** transaction.
///
/// Returns a fresh, fully-applied state. Uncommitted txns (no matching
/// [CommitTxn]) are silently dropped
///
/// `vidSpace` / `eidSpace` size the initial property-store
/// allocations; the applicator's `_ensureNodeCapacity` /
/// `_ensureEdgeCapacity` grow them as recovery progresses.
Future<MutableGraphState> recoverGraphState({
  required WalStore store,
  WalCodec codec = const WalCodec(),
  int vidSpace = 16,
  int eidSpace = 16,
}) async {
  // Empty starting state — recovery rebuilds the interner, the
  // property stores, and the overlay from scratch.
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const [],
    edgeTypeNames: const [],
    vidSpace: vidSpace,
    eidSpace: eidSpace,
  );
  await recoverInto(state, store: store, codec: codec);
  return state;
}

/// As [recoverGraphState] but replays into an existing (assumed-empty)
/// [state]. Useful for tests that want to inspect a pre-populated
/// interner or pre-built CSR alongside recovery.
Future<void> recoverInto(
  MutableGraphState state, {
  required WalStore store,
  WalCodec codec = const WalCodec(),
}) async {
  // Pass 1 — scan for committed txnIds and the highest LSN. Only the
  // txnId set is retained, not the ops: buffering every op meant peak
  // memory scaled with WAL size on top of the state being rebuilt.
  final committed = <int>{};
  var highestLsn = -1;
  await for (final seq in WalReader(store, codec: codec).replay()) {
    if (seq.op is CommitTxn) committed.add(seq.txnId);
    if (seq.lsn > highestLsn) highestLsn = seq.lsn;
  }

  // Pass 2 — re-read and apply only committed ops, skipping any the
  // loaded snapshot already covers. A decoded snapshot restores `nextLsn`
  // to its high-water mark; every WAL op below that floor was folded into
  // the snapshot (and would be dropped by the post-snapshot WAL truncate).
  // Without this gate, a crash between the checkpoint's snapshot-write and
  // WAL-truncate leaves those covered ops in the WAL, and replaying them
  // re-applies into the overlay on top of the snapshot's CSR — double-
  // counting nodes/edges. For a fresh (no-snapshot) recovery the floor is 0,
  // so everything replays.
  //
  // The reader emits in LSN order (append order within a segment), which
  // the previous implementation defensively re-sorted. Re-reading rather
  // than sorting a buffer means that defence is gone, so a future
  // segment-merge that emits out of order must restore an explicit sort
  // here — asserted below so it fails loudly rather than corrupting.
  final coveredBelowLsn = state.nextLsn;
  var lastSeenLsn = -1;
  await for (final seq in WalReader(store, codec: codec).replay()) {
    assert(
      seq.lsn > lastSeenLsn,
      'WAL replay emitted LSN ${seq.lsn} after $lastSeenLsn — recovery '
      'applies in stream order and requires ascending LSNs',
    );
    lastSeenLsn = seq.lsn;
    if (seq.lsn < coveredBelowLsn) continue; // already in the snapshot
    if (!committed.contains(seq.txnId)) continue;
    apply(state, seq, recovery: true);
  }

  // The applicator's allocators may have bumped past the committed
  // ops via fast-forward; ensure the LSN counter is just past the
  // highest one we saw, so future appends sit at lsn = highestLsn+1.
  if (highestLsn >= state.nextLsn) {
    while (state.nextLsn <= highestLsn) {
      state.allocLsn();
    }
  }
}

/// Convenience — recovers + wires a [WalWriter] sink, returning a
/// ready-to-use [GraphDb]. The single entry-point most callers want
/// for WAL-backed durability.
///
/// [snapshot] — optional snapshot bytes to load
/// **before** WAL replay. When provided, the state is reconstructed
/// from the snapshot and only WAL ops past the snapshot's LSN are
/// replayed. The snapshot's `nextLsn` field tells recovery where to
/// resume (callers are responsible for ensuring the WAL contents
/// match the snapshot — typically by having taken the snapshot +
/// truncated the WAL together; see [compactToCurrentTip]).
///
/// [snapshotStore] — optional engine-managed snapshot persistence. When
/// given and no explicit [snapshot] bytes are passed, the latest snapshot
/// is loaded from it before WAL replay. Combine with [checkpoint] to wire
/// automatic compaction (snapshot + WAL truncate on a threshold):
///
/// ```dart
/// openWalBackedGraphDb(
///   store: store,
///   snapshotStore: snaps,
///   checkpoint: CheckpointPolicy.auto(maxWalBytes: 1 << 20),
/// );
/// ```
///
/// The attached coordinator is owned by the returned engine (it runs for
/// the life of the db). For an explicit handle with `checkpointNow()` /
/// clean `close()`, use `openGraphDbAtPath` / [CheckpointCoordinator].
Future<GraphDb> openWalBackedGraphDb({
  required WalStore store,
  WalCodec codec = const WalCodec(),
  Uint8List? snapshot,
  SnapshotStore? snapshotStore,
  CheckpointPolicy checkpoint = CheckpointPolicy.disabled,
}) async {
  final snap =
      snapshot ?? (snapshotStore != null ? await snapshotStore.read() : null);
  final state = snap != null
      ? decodeSnapshot(snap)
      : await recoverGraphState(store: store, codec: codec);
  if (snap != null) {
    // Replay any WAL ops the snapshot doesn't already cover.
    await recoverInto(state, store: store, codec: codec);
  }
  final writer = WalWriter(store, codec: codec);
  final db = GraphDb.fromState(state, sink: writer);
  if (snapshotStore != null && checkpoint.isEnabled) {
    CheckpointCoordinator(
      db: db,
      walStore: store,
      snapshotStore: snapshotStore,
      policy: checkpoint,
    ).attach();
  }
  return db;
}

/// Truncates the WAL up to its current length.
/// Call **after** persisting a snapshot of the same state — the
/// snapshot owns the recovery contract for everything the truncate
/// just dropped.
///
/// Returns the byte offset retained (segment-aligned; may be less
/// than requested per the store's truncate semantics).
Future<int> compactToCurrentTip({required WalStore store}) async {
  return store.truncate(upToOffset: store.length);
}
