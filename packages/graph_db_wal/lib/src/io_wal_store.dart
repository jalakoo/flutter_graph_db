import 'dart:io';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'wal_store.dart';

/// `dart:io` `RandomAccessFile`-backed [WalStore] adapter (plan §11).
/// The default on iOS / Android / desktop.
///
/// **Phase 0 skeleton — single-file mode.** The rotated 16 MB segment
/// layout (§6.2) lands in Phase 2 alongside truncate-by-whole-segment.
/// For now [truncate] throws [UnimplementedError]; the rest of the
/// `WalStore` contract is honoured.
class IoWalStore implements WalStore {
  final File _file;
  RandomAccessFile? _raf;
  int _length;
  bool _closed = false;

  IoWalStore._(this._file, this._raf, this._length);

  /// Opens (or creates) the WAL file at [path].
  static Future<IoWalStore> open(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.append);
    final length = await raf.length();
    return IoWalStore._(file, raf, length);
  }

  @override
  Future<void> append(
    Uint8List bytes, {
    required Durability durability,
  }) async {
    _ensureOpen();
    await _raf!.writeFrom(bytes);
    _length += bytes.length;
    if (durability == Durability.fsync) {
      await _raf!.flush();
    }
    // `group`, `periodic`, and `none` are routed through the engine's
    // group-commit / timer logic — that layer calls [sync] at the
    // configured cadence. Phase 0 leaves the timer plumbing to Phase 2.
  }

  @override
  Stream<Uint8List> read({int fromOffset = 0}) async* {
    _ensureOpen();
    // Open a separate read handle so concurrent appends don't fight the
    // read cursor.
    final reader = await _file.open();
    try {
      await reader.setPosition(fromOffset);
      const chunkSize = 64 * 1024;
      while (true) {
        final chunk = await reader.read(chunkSize);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      await reader.close();
    }
  }

  @override
  int get length => _length;

  @override
  Future<int> truncate({required int upToOffset}) async {
    _ensureOpen();
    throw UnimplementedError(
        'IoWalStore truncate lands in Phase 2 alongside the rotated '
        '16 MB segment layout (plan §6.2).');
  }

  @override
  Future<void> sync() async {
    _ensureOpen();
    await _raf!.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final raf = _raf;
    _raf = null;
    if (raf != null) {
      await raf.flush();
      await raf.close();
    }
  }

  void _ensureOpen() {
    if (_closed || _raf == null) {
      throw StateError('WalStore is closed');
    }
  }
}
