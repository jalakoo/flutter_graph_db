/// `dart:io` file-backed [SyncStateStore].
///
/// Behind its own library entry point (`package:graph_db_sync/`
/// `io_sync_state_store.dart`) so a web build of the sync engine keeps
/// `dart:io` out of its dependency cone — same split the WAL package
/// uses for `IoWalStore`.
library;

import 'dart:convert';
import 'dart:io';

import 'sync_state_store.dart';

/// Stores every target's state as one small JSON object.
///
/// Writes are atomic: the new content goes to a sibling temp file, is
/// fsynced, then renamed over the target. A crash therefore leaves either
/// the previous complete state or the new one — never a half-written file
/// that would fail to parse and lose every target's progress at once.
class IoSyncStateStore implements SyncStateStore {
  final File _file;
  Map<String, SyncTargetState>? _cache;
  bool _closed = false;

  IoSyncStateStore._(this._file);

  /// Opens (or prepares to create) the state file at [path].
  static Future<IoSyncStateStore> open(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return IoSyncStateStore._(file);
  }

  @override
  Future<Map<String, SyncTargetState>> readAll() async {
    _ensureOpen();
    final cached = _cache;
    if (cached != null) return Map.of(cached);
    if (!await _file.exists()) {
      _cache = {};
      return {};
    }
    final raw = await _file.readAsString();
    if (raw.trim().isEmpty) {
      _cache = {};
      return {};
    }
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    final states = <String, SyncTargetState>{
      for (final e in decoded.entries)
        e.key: SyncTargetState.fromJson(e.value! as Map<String, Object?>),
    };
    _cache = states;
    return Map.of(states);
  }

  @override
  Future<void> write(String targetName, SyncTargetState state) async {
    _ensureOpen();
    final states = await readAll();
    states[targetName] = state;
    await _persist(states);
  }

  @override
  Future<void> delete(String targetName) async {
    _ensureOpen();
    final states = await readAll();
    if (states.remove(targetName) == null) return;
    await _persist(states);
  }

  Future<void> _persist(Map<String, SyncTargetState> states) async {
    final tmp = File('${_file.path}.tmp');
    final payload =
        jsonEncode({for (final e in states.entries) e.key: e.value.toJson()});
    // `flush: true` so the bytes are durable before the rename publishes
    // them.
    await tmp.writeAsString(payload, flush: true);
    try {
      await tmp.rename(_file.path);
    } on FileSystemException {
      // Windows can refuse rename-over-existing.
      if (await _file.exists()) await _file.delete();
      await tmp.rename(_file.path);
    }
    _cache = Map.of(states);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _cache = null;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('IoSyncStateStore is closed');
  }
}
