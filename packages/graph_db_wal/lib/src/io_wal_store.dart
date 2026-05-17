import 'dart:io';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'wal_store.dart';

/// `dart:io` `RandomAccessFile`-backed [WalStore] adapter (plan §11).
/// The default on iOS / Android / desktop.
///
/// **Single-file mode.** All bytes live in one file at the given path.
/// [truncate] is implemented via tail-rewrite (read the kept tail
/// into memory, overwrite from byte 0, truncate the file to the new
/// length). This works for typical WAL sizes (<100 MB) but rewrites
/// the whole file on each compact; the rotated 16 MB segment layout
/// (plan §6.2) is the proper polish — O(1) truncate via segment-file
/// delete. Tracked as a Phase 2 carry-forward.
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
    if (upToOffset <= 0) return 0;
    if (upToOffset >= _length) {
      // Truncating the entire file — fast path: zero it.
      await _raf!.setPosition(0);
      await _raf!.truncate(0);
      await _raf!.flush();
      _length = 0;
      return upToOffset;
    }
    // Tail-rewrite: read [upToOffset..length) into memory, overwrite
    // from byte 0, truncate to the new length. The whole-file rewrite
    // cost is the trade-off for staying in single-file mode; the
    // rotated-segment design (§6.2) gets to O(1) per compact.
    final tailLength = _length - upToOffset;
    final reader = await _file.open();
    Uint8List tail;
    try {
      await reader.setPosition(upToOffset);
      tail = await reader.read(tailLength);
    } finally {
      await reader.close();
    }
    // The append handle is `FileMode.append` which appends regardless
    // of `setPosition`. Reopen in write mode for the rewrite, then
    // restore the append handle so subsequent appends work normally.
    await _raf!.close();
    final rewrite = await _file.open(mode: FileMode.write);
    try {
      await rewrite.writeFrom(tail);
      await rewrite.truncate(tailLength);
      await rewrite.flush();
    } finally {
      await rewrite.close();
    }
    _raf = await _file.open(mode: FileMode.append);
    _length = tailLength;
    return upToOffset;
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
