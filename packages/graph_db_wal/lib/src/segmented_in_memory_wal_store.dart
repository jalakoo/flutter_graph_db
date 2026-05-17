/// In-memory [WalStore] that rotates segments (plan §6.2 / §14 Phase 2D).
///
/// Each appended frame lands in the active segment. When the active
/// segment would exceed [segmentSize], a fresh segment is started. The
/// physical segment boundary makes [truncate] cheap and **aligned** —
/// it drops whole segments and never rewrites a partial one. The
/// `dart:io` variant (Phase 2D polish) maps the same shape to one file
/// per segment.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'wal_store.dart';

/// Per plan §6.2 — 16 MB default segment size.
const int kDefaultWalSegmentBytes = 16 * 1024 * 1024;

class SegmentedInMemoryWalStore implements WalStore {
  /// Soft upper bound on a single segment's size. An append never
  /// straddles a segment boundary; if the next append would overflow
  /// the active segment, a fresh segment is started first. Individual
  /// frames larger than [segmentSize] are accepted (one frame per
  /// segment) but the WAL codec keeps frames small (§6.1).
  final int segmentSize;

  /// Closed segments — their bytes are immutable once written.
  final List<Uint8List> _closedSegments = [];

  /// Start offset of each closed segment, parallel to [_closedSegments].
  final List<int> _closedSegmentStarts = [];

  /// Active (growing) segment. Always corresponds to `_length -
  /// _activeFill` start offset.
  Uint8List _active;
  int _activeFill = 0;

  int _length = 0;
  int _truncatedBefore = 0;
  bool _closed = false;

  SegmentedInMemoryWalStore({this.segmentSize = kDefaultWalSegmentBytes})
      : _active = Uint8List(segmentSize);

  @override
  Future<void> append(
    Uint8List bytes,
    {required Durability durability}) async {
    _ensureOpen();
    // Rotate if this frame would overflow the active segment AND the
    // active segment already has data (don't rotate an empty segment
    // just because a single frame exceeds it).
    if (_activeFill > 0 && _activeFill + bytes.length > segmentSize) {
      _rotate();
    }
    if (bytes.length <= _active.length - _activeFill) {
      _active.setRange(_activeFill, _activeFill + bytes.length, bytes);
      _activeFill += bytes.length;
    } else {
      // Frame larger than segmentSize — give it its own segment.
      _closedSegments.add(Uint8List.fromList(bytes));
      _closedSegmentStarts.add(_length);
    }
    _length += bytes.length;
  }

  void _rotate() {
    final closed = Uint8List.sublistView(_active, 0, _activeFill);
    _closedSegments.add(Uint8List.fromList(closed));
    _closedSegmentStarts.add(_length - _activeFill);
    _active = Uint8List(segmentSize);
    _activeFill = 0;
  }

  @override
  Stream<Uint8List> read({int fromOffset = 0}) async* {
    _ensureOpen();
    // Asking for bytes < the truncate boundary is benign — silently
    // advance to the boundary. Matches what a file-backed adapter
    // does after a truncate (the file starts at the kept tail).
    if (fromOffset < _truncatedBefore) fromOffset = _truncatedBefore;
    // Yield closed segments first.
    for (var i = 0; i < _closedSegments.length; i++) {
      final seg = _closedSegments[i];
      final start = _closedSegmentStarts[i];
      final end = start + seg.length;
      if (end <= fromOffset) continue;
      if (start >= fromOffset) {
        yield seg;
      } else {
        yield Uint8List.sublistView(seg, fromOffset - start);
      }
    }
    // Then the live active segment.
    if (_activeFill > 0) {
      final activeStart = _length - _activeFill;
      if (activeStart + _activeFill > fromOffset) {
        final view = Uint8List.sublistView(_active, 0, _activeFill);
        if (activeStart >= fromOffset) {
          yield Uint8List.fromList(view);
        } else {
          yield Uint8List.sublistView(view, fromOffset - activeStart);
        }
      }
    }
  }

  @override
  int get length => _length;

  /// Drops every **complete** segment whose end-offset is at or below
  /// [upToOffset]. The currently-active segment is never truncated —
  /// new writes continue to append to it. Returns the actual offset
  /// after which data is retained (may be less than [upToOffset]
  /// because of segment alignment).
  @override
  Future<int> truncate({required int upToOffset}) async {
    _ensureOpen();
    if (upToOffset <= _truncatedBefore) return _truncatedBefore;
    while (_closedSegments.isNotEmpty) {
      final start = _closedSegmentStarts.first;
      final end = start + _closedSegments.first.length;
      if (end > upToOffset) break;
      _closedSegments.removeAt(0);
      _closedSegmentStarts.removeAt(0);
      _truncatedBefore = end;
    }
    return _truncatedBefore;
  }

  @override
  Future<void> sync() async {
    _ensureOpen();
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  /// In-memory only — same shape as [InMemoryWalStore.reopen] so a
  /// test fixture can simulate "shut down + reopen" on the same
  /// instance.
  void reopen() {
    _closed = false;
  }

  /// Number of closed (rotated-out) segments. Exposed for tests + for
  /// reasoning about truncate granularity.
  int get closedSegmentCount => _closedSegments.length;

  /// Number of bytes in the currently-active segment.
  int get activeSegmentFill => _activeFill;

  void _ensureOpen() {
    if (_closed) throw StateError('WalStore is closed');
  }
}
