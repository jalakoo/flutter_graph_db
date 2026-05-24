import 'dart:typed_data';

import 'snapshot_store.dart';

/// In-memory [SnapshotStore] adapter. Used for tests and as the web
/// fallback (until an IndexedDB snapshot adapter lands).
class InMemorySnapshotStore implements SnapshotStore {
  Uint8List? _bytes;
  bool _closed = false;

  InMemorySnapshotStore();

  @override
  Future<void> write(Uint8List bytes) async {
    _ensureOpen();
    // Copy so a later mutation of the caller's buffer can't corrupt the
    // stored snapshot. The swap is the "atomic replace".
    _bytes = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> read() async {
    _ensureOpen();
    final b = _bytes;
    return b == null ? null : Uint8List.fromList(b);
  }

  @override
  Future<void> delete() async {
    _ensureOpen();
    _bytes = null;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('SnapshotStore is closed');
  }
}
