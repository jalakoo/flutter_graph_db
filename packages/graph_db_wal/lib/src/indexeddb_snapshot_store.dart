/// Browser-side [SnapshotStore] backed by IndexedDB.
///
/// **Schema:** one DB named [dbName] (default `graph_db_snapshot`), one
/// object store `snapshot` with a single fixed key holding the latest
/// snapshot bytes. [write] is a `put` at that key — an atomic
/// single-latest replace, matching the [SnapshotStore] contract.
///
/// **Validation status.** Follows the IndexedDB spec and compiles to
/// `dart2js` + `dart2wasm` (mirrors the validated `IndexedDbWalStore`).
/// Browser integration tests (`dart test -p chrome`) are a polish
/// follow-up, as with the WAL adapter.
///
/// **Native builds.** Imports `package:web`; only links on web targets.
/// Not exported from `graph_db_wal.dart` — opt in via
/// `package:graph_db_wal/indexeddb_wal_store.dart`.
@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'snapshot_store.dart';

const String _kDefaultDbName = 'graph_db_snapshot';
const String _kStore = 'snapshot';
const int _kKey = 0; // single-latest: one fixed record
const int _kSchemaVersion = 1;

/// Opens (or creates) an IndexedDB-backed [SnapshotStore].
Future<IndexedDbSnapshotStore> openIndexedDbSnapshotStore({
  String dbName = _kDefaultDbName,
}) async {
  final db = await _openDb(dbName);
  return IndexedDbSnapshotStore._(db, dbName);
}

class IndexedDbSnapshotStore implements SnapshotStore {
  final web.IDBDatabase _db;
  final String _dbName;
  bool _closed = false;

  IndexedDbSnapshotStore._(this._db, this._dbName);

  @override
  Future<void> write(Uint8List bytes) async {
    _ensureOpen();
    final tx = _db.transaction(_kStore.toJS, 'readwrite');
    // put at the fixed key replaces any prior snapshot atomically; the
    // bytes are durable once the transaction's `complete` fires.
    tx.objectStore(_kStore).put(bytes.toJS, _kKey.toJS);
    await _completion(tx);
  }

  @override
  Future<Uint8List?> read() async {
    _ensureOpen();
    final tx = _db.transaction(_kStore.toJS, 'readonly');
    final req = tx.objectStore(_kStore).get(_kKey.toJS);
    final c = Completer<Uint8List?>();
    req.onsuccess = ((web.Event _) {
      final result = req.result; // JSAny? — null/undefined when absent
      c.complete(result == null ? null : (result as JSUint8Array).toDart);
    }).toJS;
    req.onerror = ((web.Event _) {
      if (!c.isCompleted) {
        c.completeError(StateError(
            'IndexedDbSnapshotStore.read: ${req.error?.message}'));
      }
    }).toJS;
    return c.future;
  }

  @override
  Future<void> delete() async {
    _ensureOpen();
    final tx = _db.transaction(_kStore.toJS, 'readwrite');
    tx.objectStore(_kStore).delete(_kKey.toJS);
    await _completion(tx);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  /// **Test-only.** Deletes the underlying IndexedDB database so the next
  /// [openIndexedDbSnapshotStore] starts fresh.
  Future<void> deleteDatabase() async {
    await close();
    final req = web.window.indexedDB.deleteDatabase(_dbName);
    final c = Completer<void>();
    req.onsuccess = ((web.Event _) {
      if (!c.isCompleted) c.complete();
    }).toJS;
    req.onerror = ((web.Event _) {
      if (!c.isCompleted) {
        c.completeError(StateError('deleteDatabase failed: ${req.error}'));
      }
    }).toJS;
    await c.future;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('IndexedDbSnapshotStore is closed.');
  }
}

/// Awaits an [web.IDBTransaction]'s `complete` event.
Future<void> _completion(web.IDBTransaction tx) {
  final c = Completer<void>();
  tx.oncomplete = ((web.Event _) {
    if (!c.isCompleted) c.complete();
  }).toJS;
  tx.onerror = ((web.Event _) {
    if (!c.isCompleted) {
      c.completeError(StateError('IDB transaction error: ${tx.error?.message}'));
    }
  }).toJS;
  tx.onabort = ((web.Event _) {
    if (!c.isCompleted) c.completeError(StateError('IDB transaction aborted'));
  }).toJS;
  return c.future;
}

Future<web.IDBDatabase> _openDb(String name) {
  final req = web.window.indexedDB.open(name, _kSchemaVersion);
  final c = Completer<web.IDBDatabase>();
  req.onupgradeneeded = ((web.IDBVersionChangeEvent _) {
    final db = req.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_kStore)) {
      // Out-of-line keys (no keyPath / autoIncrement) — we supply the
      // fixed key explicitly on every put.
      db.createObjectStore(_kStore);
    }
  }).toJS;
  req.onsuccess = ((web.Event _) {
    if (!c.isCompleted) c.complete(req.result as web.IDBDatabase);
  }).toJS;
  req.onerror = ((web.Event _) {
    if (!c.isCompleted) {
      c.completeError(StateError('IDB open failed: ${req.error?.message}'));
    }
  }).toJS;
  req.onblocked = ((web.Event _) {
    if (!c.isCompleted) {
      c.completeError(StateError('IDB open blocked (another tab holds it)'));
    }
  }).toJS;
  return c.future;
}
