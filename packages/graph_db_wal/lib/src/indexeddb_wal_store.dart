/// Browser-side [WalStore] backed by IndexedDB.
///
/// **Schema:**
///   - one DB named [dbName] (default `graph_db_wal`)
///   - one object store `chunks`, auto-increment key (1, 2, 3, …)
///   - per-record value = `{offset: int, bytes: Uint8List}` — offset is
///     the byte position the chunk lands at in the logical log; bytes
///     is the raw payload the caller passed to [append]
///
/// **Why store [offset] explicitly?** IndexedDB keys monotonically
/// increase but are *not* byte offsets — after a [truncate] the surviving
/// records can start anywhere. The byte-offset field lets [read] and
/// [truncate] map plan-level byte addresses to the right records without
/// a separate index.
///
/// **Validation status.** This adapter follows the IndexedDB spec exactly
/// and compiles cleanly to `dart2js` + `dart2wasm`. Browser-side
/// integration tests (`dart test -p chrome`) are themselves a polish
/// follow-up — the in-memory + io adapters are the validated ones for
/// v1.
///
/// **Native builds.** This file imports `package:web` and only links on
/// web targets; do not export it from `graph_db_wal.dart`. Consumers
/// targeting the browser opt in via
/// `package:graph_db_wal/indexeddb_wal_store.dart`.
@JS()
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:web/web.dart' as web;

import 'wal_store.dart';

const String _kDefaultDbName = 'graph_db_wal';
const String _kChunkStore = 'chunks';
const int _kSchemaVersion = 1;

/// Opens (or creates) an IndexedDB-backed [WalStore].
///
/// Returns once the IndexedDB upgrade transaction (if any) has settled
/// and the existing chunks have been scanned to recover the in-memory
/// `length` and `truncatedBefore` values.
Future<IndexedDbWalStore> openIndexedDbWalStore({
  String dbName = _kDefaultDbName,
}) async {
  final db = await _openDb(dbName);
  final store = IndexedDbWalStore._(db, dbName);
  await store._recoverMetadata();
  return store;
}

class IndexedDbWalStore implements WalStore {
  final web.IDBDatabase _db;
  final String _dbName;
  bool _closed = false;
  int _length = 0;
  int _truncatedBefore = 0;

  IndexedDbWalStore._(this._db, this._dbName);

  @override
  int get length => _length;

  /// Visible for tests / diagnostics — the byte offset before which all
  /// data has been compacted away.
  int get truncatedBefore => _truncatedBefore;

  @override
  Future<void> append(
    Uint8List bytes, {
    required Durability durability,
  }) async {
    _ensureOpen();
    if (bytes.isEmpty) return;
    final tx = _db.transaction(_kChunkStore.toJS, 'readwrite');
    final store = tx.objectStore(_kChunkStore);
    final offset = _length;
    final value = _ChunkValue(offset: offset, bytes: bytes).toJs();
    store.add(value);
    await _completion(tx);
    _length += bytes.length;
    // Durability.fsync semantics: IndexedDB doesn't expose an explicit
    // fsync — the transaction's `complete` event fires after the UA's
    // own durability promise. We treat that as our fsync; group /
    // periodic batching is the engine's responsibility above.
  }

  @override
  Stream<Uint8List> read({int fromOffset = 0}) async* {
    _ensureOpen();
    final effectiveFrom =
        fromOffset < _truncatedBefore ? _truncatedBefore : fromOffset;
    if (effectiveFrom >= _length) return;

    final tx = _db.transaction(_kChunkStore.toJS, 'readonly');
    final store = tx.objectStore(_kChunkStore);
    final completer = Completer<List<Uint8List>>();
    final out = <Uint8List>[];
    final req = store.openCursor();
    req.onsuccess = ((web.Event _) {
      final cursor = req.result as web.IDBCursorWithValue?;
      if (cursor == null) {
        completer.complete(out);
        return;
      }
      final chunk = _ChunkValue.fromJs(cursor.value as JSObject);
      final chunkEnd = chunk.offset + chunk.bytes.length;
      if (chunkEnd > effectiveFrom) {
        if (chunk.offset >= effectiveFrom) {
          out.add(chunk.bytes);
        } else {
          out.add(Uint8List.sublistView(
            chunk.bytes,
            effectiveFrom - chunk.offset,
          ));
        }
      }
      cursor.continue_();
    }).toJS;
    req.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(
            'IndexedDbWalStore.read: cursor error ${req.error?.message}'));
      }
    }).toJS;

    final chunks = await completer.future;
    for (final c in chunks) {
      yield c;
    }
  }

  @override
  Future<int> truncate({required int upToOffset}) async {
    _ensureOpen();
    if (upToOffset <= _truncatedBefore) return _truncatedBefore;
    final tx = _db.transaction(_kChunkStore.toJS, 'readwrite');
    final store = tx.objectStore(_kChunkStore);
    final completer = Completer<int>();
    var newFloor = _truncatedBefore;
    final req = store.openCursor();
    req.onsuccess = ((web.Event _) {
      final cursor = req.result as web.IDBCursorWithValue?;
      if (cursor == null) {
        completer.complete(newFloor);
        return;
      }
      final chunk = _ChunkValue.fromJs(cursor.value as JSObject);
      final chunkEnd = chunk.offset + chunk.bytes.length;
      if (chunkEnd <= upToOffset) {
        // Whole chunk falls below the truncate point — drop it.
        cursor.delete();
        if (chunkEnd > newFloor) newFloor = chunkEnd;
      }
      // Partial chunks straddling the truncate point are kept; the
      // file-backed adapter rounds to segment boundaries the same way.
      cursor.continue_();
    }).toJS;
    req.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(
            'IndexedDbWalStore.truncate: cursor error ${req.error?.message}'));
      }
    }).toJS;
    final floor = await completer.future;
    await _completion(tx);
    _truncatedBefore = floor;
    return _truncatedBefore;
  }

  @override
  Future<void> sync() async {
    // IndexedDB writes durability is bound to the transaction commit,
    // which already happened by the time [append]'s future resolved.
    // Nothing to do here — exists for symmetry with the io adapter.
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  /// **Test-only.** Deletes the underlying IndexedDB database so the
  /// next [openIndexedDbWalStore] starts fresh. Used by browser tests
  /// and to reset state in dev tools.
  Future<void> deleteDatabase() async {
    await close();
    final req = web.window.indexedDB.deleteDatabase(_dbName);
    final c = Completer<void>();
    req.onsuccess = ((web.Event _) => c.complete()).toJS;
    req.onerror = ((web.Event _) {
      if (!c.isCompleted) {
        c.completeError(StateError('deleteDatabase failed: ${req.error}'));
      }
    }).toJS;
    await c.future;
  }

  Future<void> _recoverMetadata() async {
    // Walk every record once at open-time to populate _length +
    // _truncatedBefore from the existing chunks. O(N records); for a
    // typical browser-side WAL this is bounded by `kDefaultWalSegmentBytes`
    // and a handful of segments, so it's fast in practice.
    final tx = _db.transaction(_kChunkStore.toJS, 'readonly');
    final store = tx.objectStore(_kChunkStore);
    final completer = Completer<({int length, int floor})>();
    var maxEnd = 0;
    var minOffset = -1; // -1 = sentinel "no chunks yet"
    final req = store.openCursor();
    req.onsuccess = ((web.Event _) {
      final cursor = req.result as web.IDBCursorWithValue?;
      if (cursor == null) {
        completer.complete((
          length: maxEnd,
          floor: minOffset == -1 ? 0 : minOffset,
        ));
        return;
      }
      final chunk = _ChunkValue.fromJs(cursor.value as JSObject);
      final end = chunk.offset + chunk.bytes.length;
      if (end > maxEnd) maxEnd = end;
      if (minOffset == -1 || chunk.offset < minOffset) {
        minOffset = chunk.offset;
      }
      cursor.continue_();
    }).toJS;
    req.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(
            'IndexedDbWalStore._recoverMetadata: ${req.error?.message}'));
      }
    }).toJS;
    final m = await completer.future;
    _length = m.length;
    _truncatedBefore = m.floor;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('IndexedDbWalStore is closed.');
    }
  }
}

/// Awaits an [IDBTransaction]'s `complete` event.
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
    if (!c.isCompleted) {
      c.completeError(StateError('IDB transaction aborted'));
    }
  }).toJS;
  return c.future;
}

Future<web.IDBDatabase> _openDb(String name) {
  final req = web.window.indexedDB.open(name, _kSchemaVersion);
  final c = Completer<web.IDBDatabase>();
  req.onupgradeneeded = ((web.IDBVersionChangeEvent _) {
    final db = req.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_kChunkStore)) {
      db.createObjectStore(
        _kChunkStore,
        web.IDBObjectStoreParameters(autoIncrement: true),
      );
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

/// JS-side shape of a chunk record. Extension type gives us typed
/// property access without operator `[]` (which `JSObject` does not
/// define in modern `dart:js_interop`).
extension type _ChunkRecord._(JSObject _) implements JSObject {
  external factory _ChunkRecord({
    required JSNumber offset,
    required JSUint8Array bytes,
  });

  external JSNumber get offset;
  external JSUint8Array get bytes;
}

/// Plain Dart view over [_ChunkRecord] — keeps the interop boundary at
/// the edges of [IndexedDbWalStore].
class _ChunkValue {
  final int offset;
  final Uint8List bytes;
  const _ChunkValue({required this.offset, required this.bytes});

  JSObject toJs() => _ChunkRecord(
        offset: offset.toJS,
        bytes: bytes.toJS,
      );

  factory _ChunkValue.fromJs(JSObject o) {
    final r = o as _ChunkRecord;
    return _ChunkValue(
      offset: r.offset.toDartInt,
      bytes: r.bytes.toDart,
    );
  }
}
