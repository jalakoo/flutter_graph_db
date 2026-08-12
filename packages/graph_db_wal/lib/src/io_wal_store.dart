import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'wal_store.dart';

/// `dart:io` `RandomAccessFile`-backed [WalStore] adapter.
/// The default on iOS / Android / desktop.
///
/// **Single-file mode.** All bytes live in one file at the given path.
/// [truncate] copies the retained tail to a sibling temp file, fsyncs it,
/// and renames it over the WAL — so the rewrite is atomic and streams in
/// bounded chunks. It still rewrites the retained bytes on each compact;
/// the rotated 16 MB segment layout is the proper fix (O(1) truncate via
/// segment-file delete) and stays a carry-forward.
class IoWalStore implements WalStore {
  final File _file;
  RandomAccessFile? _raf;
  int _length;

  /// Set inside the queued [close] body — this is what [_ensureOpen]
  /// reads, so queue position decides whether an operation was in time.
  bool _closed = false;

  /// Set synchronously by [close] purely for idempotence.
  bool _closeRequested = false;

  /// Chunk size for the streaming tail copy in [truncate] and for
  /// [read]. Bounds truncate's peak memory regardless of WAL size.
  static const int _chunkSize = 64 * 1024;

  /// Suffix for the temp file [truncate] builds before renaming it over
  /// the WAL. A leftover of this name means a crash mid-truncate; it is
  /// stale by definition and removed on the next [truncate].
  static const String _compactSuffix = '.compact';

  /// Tail of the handle-mutation queue. [append], [sync], [truncate] and
  /// [close] all run through [_serialize], because [truncate] has to
  /// close and reopen `_raf` around its rename: without the queue, a
  /// group-commit `sync()` landing in that window sees a null handle and
  /// throws "WalStore is closed" while the store is perfectly healthy.
  ///
  /// Never completes with an error — [_serialize] completes the gate in a
  /// `whenComplete`, so one failed operation cannot poison the queue.
  Future<void> _queue = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() op) {
    final previous = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    return previous.then((_) => op()).whenComplete(gate.complete);
  }

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
  }) =>
      _serialize(() => _appendLocked(bytes, durability));

  Future<void> _appendLocked(Uint8List bytes, Durability durability) async {
    _ensureOpen();
    await _raf!.writeFrom(bytes);
    _length += bytes.length;
    if (durability == Durability.fsync) {
      await _raf!.flush();
    }
    // `group`, `periodic`, and `none` are routed through the engine's
    // group-commit / timer logic — that layer calls [sync] at the
    // configured cadence. The timer plumbing lives in the engine, not
    // here.
  }

  @override
  Stream<Uint8List> read({int fromOffset = 0}) async* {
    _ensureOpen();
    // Open a separate read handle so concurrent appends don't fight the
    // read cursor.
    final reader = await _file.open();
    try {
      await reader.setPosition(fromOffset);
      const chunkSize = _chunkSize;
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

  /// Drops everything before [upToOffset], keeping the tail.
  ///
  /// **Crash-safe.** The retained tail is streamed into a sibling temp
  /// file, fsynced, and then renamed over the WAL — rename is atomic, so
  /// a crash at any point leaves either the old complete WAL or the new
  /// complete one. Nothing in between is observable.
  ///
  /// This replaced a destructive in-place rewrite that reopened the WAL
  /// with `FileMode.write` (truncating it to zero) before writing the
  /// tail back. A crash inside that window lost the entire tail — i.e.
  /// every commit acknowledged after the snapshot was captured, which is
  /// exactly the data the snapshot does *not* cover.
  ///
  /// Peak memory is one [_chunkSize] buffer, not the whole tail.
  @override
  Future<int> truncate({required int upToOffset}) =>
      _serialize(() => _truncateLocked(upToOffset));

  Future<int> _truncateLocked(int upToOffset) async {
    _ensureOpen();
    if (upToOffset <= 0) return 0;
    if (upToOffset >= _length) {
      // Dropping everything. `truncate(0)` on the live handle is already
      // atomic — there is no tail to stage.
      await _raf!.truncate(0);
      await _raf!.flush();
      await _raf!.setPosition(0);
      _length = 0;
      return upToOffset;
    }

    final tailLength = _length - upToOffset;
    final tmp = File('${_file.path}$_compactSuffix');
    // A leftover temp file is stale by definition — it belongs to a
    // truncate that never reached its rename.
    if (tmp.existsSync()) await tmp.delete();

    final reader = await _file.open();
    final writer = await tmp.open(mode: FileMode.write);
    try {
      await reader.setPosition(upToOffset);
      var remaining = tailLength;
      while (remaining > 0) {
        final want = remaining < _chunkSize ? remaining : _chunkSize;
        final chunk = await reader.read(want);
        if (chunk.isEmpty) break; // file shrank underneath us
        await writer.writeFrom(chunk);
        remaining -= chunk.length;
      }
      // Durable before the rename: the rename must never publish a temp
      // file whose bytes are still in the page cache.
      await writer.flush();
    } finally {
      await reader.close();
      await writer.close();
    }

    // Release our handle before the rename — Windows refuses to replace
    // a file that still has an open handle. Nothing else can observe the
    // null handle: append / sync / close all queue behind this call.
    await _raf!.flush();
    await _raf!.close();
    _raf = null;
    try {
      try {
        await tmp.rename(_file.path);
      } on FileSystemException {
        // Windows can refuse rename-over-existing. Delete then rename;
        // the snapshot still covers everything dropped here, so a crash
        // in this narrow window is recoverable from the snapshot alone.
        await _file.delete();
        await tmp.rename(_file.path);
      }
      _length = tailLength;
    } finally {
      // Always restore a usable handle, even if the rename failed —
      // otherwise every later operation reports the store as closed and
      // buries the real error.
      _raf = await _file.open(mode: FileMode.append);
      _length = await _raf!.length();
    }
    return upToOffset;
  }

  @override
  Future<void> sync() => _serialize(() async {
        _ensureOpen();
        await _raf!.flush();
      });

  @override
  Future<void> close() {
    // `_closeRequested` flips synchronously so a second close is a no-op.
    // `_closed` — the flag `_ensureOpen` reads — is set inside the queued
    // body instead, so operations already queued ahead of this close
    // still run. Setting it synchronously would reject a truncate that
    // was requested first and merely hadn't started yet.
    if (_closeRequested) return Future<void>.value();
    _closeRequested = true;
    return _serialize(() async {
      _closed = true;
      final raf = _raf;
      _raf = null;
      if (raf != null) {
        await raf.flush();
        await raf.close();
      }
    });
  }

  void _ensureOpen() {
    if (_closed || _raf == null) {
      throw StateError('WalStore is closed');
    }
  }
}
