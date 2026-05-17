import 'dart:async';

import 'package:graph_db_core/graph_db_core.dart';

import 'codec/wal_codec.dart';
import 'wal_store.dart';

/// Frames + encodes [SequencedWalOp]s per the §6.1 schema, appends to
/// the underlying [WalStore], and coalesces fsyncs across transactions
/// via a **group-commit** window (plan §6.7).
///
/// Implements [WalSink] (plan §2.2) so it plugs directly into
/// `GraphDb.fromState(..., sink: walWriter)`.
///
/// Group-commit policy (Phase 2D):
/// - [Durability.fsync] — synchronous fsync at the end of the call.
///   Lowest latency variance, highest fsync count.
/// - [Durability.group] (default) — append + register a completer,
///   start the group timer if it isn't running, return the completer's
///   future. Multiple concurrent txns share one fsync per [groupWindow].
/// - [Durability.periodic] — append + register on the same group
///   queue; the group timer is the only fsync trigger. v1 treats this
///   the same as `group` (the explicit periodic flusher lands in Phase
///   6 alongside the snapshot/checkpoint scheduler).
/// - [Durability.none] — append, no fsync, return immediately.
class WalWriter implements WalSink {
  final WalStore store;
  final WalCodec _codec;

  /// How long to wait before flushing the next group-commit batch.
  /// Default 1 ms per plan §6.7. Tests can pass [Duration.zero] for
  /// "next microtask" semantics.
  final Duration groupWindow;

  final List<Completer<void>> _pendingGroup = [];
  Timer? _groupTimer;
  bool _closed = false;

  WalWriter(
    this.store, {
    WalCodec codec = const WalCodec(),
    this.groupWindow = const Duration(milliseconds: 1),
  }) : _codec = codec;

  @override
  Future<void> append(
    SequencedWalOp op, {
    required Durability durability,
  }) async {
    _ensureOpen();
    final framed = _codec.encodeFramed(op);
    await store.append(framed, durability: durability);
    return _ackDurability(durability);
  }

  @override
  Future<void> appendBatch(
    List<SequencedWalOp> ops, {
    required Durability durability,
  }) async {
    _ensureOpen();
    // Skip the per-op fsync; the durability ack covers the whole batch.
    for (final op in ops) {
      final framed = _codec.encodeFramed(op);
      await store.append(framed, durability: Durability.none);
    }
    return _ackDurability(durability);
  }

  Future<void> _ackDurability(Durability d) {
    switch (d) {
      case Durability.fsync:
        return store.sync();
      case Durability.group:
      case Durability.periodic:
        final completer = Completer<void>();
        _pendingGroup.add(completer);
        _groupTimer ??= Timer(groupWindow, _flushGroup);
        return completer.future;
      case Durability.none:
        return Future.value();
    }
  }

  Future<void> _flushGroup() async {
    _groupTimer = null;
    if (_pendingGroup.isEmpty) return;
    final pending = List<Completer<void>>.of(_pendingGroup);
    _pendingGroup.clear();
    try {
      await store.sync();
      for (final c in pending) {
        c.complete();
      }
    } catch (e, st) {
      for (final c in pending) {
        c.completeError(e, st);
      }
    }
  }

  @override
  Future<void> sync() async {
    _ensureOpen();
    // Drain any pending group ack first, then sync the store.
    if (_groupTimer != null) {
      _groupTimer!.cancel();
      _groupTimer = null;
      await _flushGroup();
    } else {
      await store.sync();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    // Flush whatever is queued, then close the underlying store.
    await sync();
    _closed = true;
    await store.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('WalWriter is closed');
  }
}
