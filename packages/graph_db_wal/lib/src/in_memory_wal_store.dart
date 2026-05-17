import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'wal_store.dart';

/// In-memory [WalStore] adapter. Used for tests, on web (until the
/// IndexedDB adapter lands in Phase 8), and as the in-memory fixture
/// the integration suite uses for crash-injection and recovery tests
/// without touching disk (plan §2.2).
class InMemoryWalStore implements WalStore {
  final List<Uint8List> _chunks = [];
  int _length = 0;
  int _truncatedBefore = 0;
  bool _closed = false;

  InMemoryWalStore();

  @override
  Future<void> append(
    Uint8List bytes, {
    required Durability durability,
  }) async {
    _ensureOpen();
    // Copy so a later mutation of the caller's buffer doesn't corrupt
    // the log.
    _chunks.add(Uint8List.fromList(bytes));
    _length += bytes.length;
  }

  @override
  Stream<Uint8List> read({int fromOffset = 0}) async* {
    _ensureOpen();
    // Asking for bytes < the truncate boundary is benign — silently
    // advance to the boundary. Matches what a file-backed adapter
    // does after a truncate (the file starts at the kept tail).
    if (fromOffset < _truncatedBefore) fromOffset = _truncatedBefore;
    var pos = _truncatedBefore;
    for (final chunk in _chunks) {
      final chunkEnd = pos + chunk.length;
      if (chunkEnd <= fromOffset) {
        pos = chunkEnd;
        continue;
      }
      if (pos >= fromOffset) {
        yield chunk;
      } else {
        // Read straddles the start: yield the tail after the requested
        // offset.
        yield Uint8List.sublistView(chunk, fromOffset - pos);
      }
      pos = chunkEnd;
    }
  }

  @override
  int get length => _length;

  @override
  Future<int> truncate({required int upToOffset}) async {
    _ensureOpen();
    if (upToOffset <= _truncatedBefore) return _truncatedBefore;
    var pos = _truncatedBefore;
    while (_chunks.isNotEmpty && pos + _chunks.first.length <= upToOffset) {
      pos += _chunks.first.length;
      _chunks.removeAt(0);
    }
    _truncatedBefore = pos;
    return _truncatedBefore;
  }

  @override
  Future<void> sync() async {
    _ensureOpen();
    // RAM-only — no kernel buffer to flush.
  }

  @override
  Future<void> close() async {
    // Mark inert — further appends / reads on **this** handle throw.
    // The chunks are kept so the test fixture can simulate "shut down
    // + reopen" by handing the same instance to a fresh `WalWriter`
    // after a [reopen] call. Real adapters (`IoWalStore`) close a
    // kernel handle here; the bytes survive on disk regardless.
    _closed = true;
  }

  /// In-memory only — re-opens a closed store so the same fixture can
  /// be replayed in a follow-up session. Real disk-backed adapters
  /// don't need this; you simply construct a new adapter pointing at
  /// the same path.
  void reopen() {
    _closed = false;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('WalStore is closed');
  }
}
