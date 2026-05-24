import 'dart:io';
import 'dart:typed_data';

import 'snapshot_store.dart';

/// `dart:io` file-backed [SnapshotStore]. The default on iOS / Android /
/// desktop.
///
/// [write] is **atomic** on POSIX: bytes go to a sibling `<path>.tmp`,
/// are flushed, then renamed onto [path] (`rename(2)` atomically
/// replaces). A crash mid-write therefore leaves the previous snapshot
/// intact — at worst a stale `.tmp`, which the next [write] overwrites.
///
/// On Windows, where renaming onto an existing file fails, [write] falls
/// back to delete-then-rename — a narrow non-atomic window. iOS / Android
/// / macOS / Linux (the POSIX targets, including the iOS MVP) get the
/// atomic path.
class IoSnapshotStore implements SnapshotStore {
  final File _file;
  final File _tmp;
  bool _closed = false;

  IoSnapshotStore._(this._file, this._tmp);

  /// Opens (creating the parent directory) a snapshot store at [path].
  static Future<IoSnapshotStore> open(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return IoSnapshotStore._(file, File('$path.tmp'));
  }

  @override
  Future<void> write(Uint8List bytes) async {
    _ensureOpen();
    final raf = await _tmp.open(mode: FileMode.write);
    try {
      await raf.writeFrom(bytes);
      await raf.flush();
    } finally {
      await raf.close();
    }
    try {
      await _tmp.rename(_file.path);
    } on FileSystemException {
      // Windows: rename onto an existing file throws. Replace explicitly.
      if (await _file.exists()) await _file.delete();
      await _tmp.rename(_file.path);
    }
  }

  @override
  Future<Uint8List?> read() async {
    _ensureOpen();
    if (!await _file.exists()) return null;
    return _file.readAsBytes();
  }

  @override
  Future<void> delete() async {
    _ensureOpen();
    if (await _file.exists()) await _file.delete();
    if (await _tmp.exists()) await _tmp.delete();
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('SnapshotStore is closed');
  }
}
