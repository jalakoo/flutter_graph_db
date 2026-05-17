/// `logicalId` ↔ `remoteId` LRU cache.
///
/// Adapters populate the cache from query results — every
/// [`RemoteNode`] / [`RemoteEdge`] carries both ids. Subsequent
/// reads against the same logical id can short-circuit a lookup on
/// the backend by re-using the cached `remoteId`. Application code
/// deals exclusively in logical ids — the cache is an adapter-side
/// optimisation, not a user-facing surface.
///
/// Single intrusive LRU shared by both directions; the cache is
/// bounded by [maxEntries] (default 100 k). Eviction
/// removes the oldest pair from both maps. Invalidated by adapters
/// on `bulkImport` and by a public `reset()`.
library;

class _LruEntry {
  final String logicalId;
  final String remoteId;
  _LruEntry? prev;
  _LruEntry? next;
  _LruEntry({required this.logicalId, required this.remoteId});
}

/// Default LRU size
const int kDefaultIdCacheSize = 100000;

class IdTranslationCache {
  final int maxEntries;
  final Map<String, _LruEntry> _byLogical = {};
  final Map<String, _LruEntry> _byRemote = {};
  _LruEntry? _head;
  _LruEntry? _tail;

  IdTranslationCache({this.maxEntries = kDefaultIdCacheSize});

  int get length => _byLogical.length;

  /// Returns the remote id for [logicalId] if known. Moves the entry
  /// to MRU position.
  String? remoteFor(String logicalId) {
    final e = _byLogical[logicalId];
    if (e == null) return null;
    _moveToFront(e);
    return e.remoteId;
  }

  /// Returns the logical id for [remoteId] if known. Moves the entry
  /// to MRU position.
  String? logicalFor(String remoteId) {
    final e = _byRemote[remoteId];
    if (e == null) return null;
    _moveToFront(e);
    return e.logicalId;
  }

  /// Records a `(logical, remote)` pair. If either side already has a
  /// different pairing, the older entry is dropped first.
  void put(String logicalId, String remoteId) {
    final existing = _byLogical[logicalId];
    if (existing != null && existing.remoteId == remoteId) {
      _moveToFront(existing);
      return;
    }
    if (existing != null) {
      _unlink(existing);
      _byLogical.remove(existing.logicalId);
      _byRemote.remove(existing.remoteId);
    }
    final alsoExisting = _byRemote[remoteId];
    if (alsoExisting != null) {
      _unlink(alsoExisting);
      _byLogical.remove(alsoExisting.logicalId);
      _byRemote.remove(alsoExisting.remoteId);
    }
    final entry =
        _LruEntry(logicalId: logicalId, remoteId: remoteId);
    _byLogical[logicalId] = entry;
    _byRemote[remoteId] = entry;
    _insertFront(entry);
    if (_byLogical.length > maxEntries) _evictTail();
  }

  /// explicit reset — typically called after
  /// `bulkImport` invalidates every cached mapping.
  void reset() {
    _byLogical.clear();
    _byRemote.clear();
    _head = null;
    _tail = null;
  }

  void _moveToFront(_LruEntry e) {
    if (identical(_head, e)) return;
    _unlink(e);
    _insertFront(e);
  }

  void _insertFront(_LruEntry e) {
    e.prev = null;
    e.next = _head;
    _head?.prev = e;
    _head = e;
    _tail ??= e;
  }

  void _unlink(_LruEntry e) {
    if (e.prev != null) e.prev!.next = e.next;
    if (e.next != null) e.next!.prev = e.prev;
    if (identical(_head, e)) _head = e.next;
    if (identical(_tail, e)) _tail = e.prev;
    e.prev = null;
    e.next = null;
  }

  void _evictTail() {
    final t = _tail;
    if (t == null) return;
    _unlink(t);
    _byLogical.remove(t.logicalId);
    _byRemote.remove(t.remoteId);
  }
}
