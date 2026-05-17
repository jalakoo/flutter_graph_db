/// LRU plan cache (plan §8 / §14 Phase 3F).
///
/// Caches the parser + planner output keyed by the raw query string.
/// The cache is per-`GraphDb` (attached via an `Expando`) — different
/// engines may resolve the same query to different plans because of
/// distinct catalogs.
library;

import 'plan/logical_plan.dart';

/// Default cache size per plan §8.
const int kDefaultPlanCacheSize = 64;

class _LruEntry {
  final String key;
  LogicalPlan plan;
  _LruEntry? prev;
  _LruEntry? next;
  _LruEntry(this.key, this.plan);
}

/// Simple intrusive doubly-linked-list LRU. Not isolate-safe (the
/// engine is single-writer per plan §2.3).
class GqlPlanCache {
  final int maxEntries;
  final Map<String, _LruEntry> _map = {};
  _LruEntry? _head;
  _LruEntry? _tail;

  GqlPlanCache({this.maxEntries = kDefaultPlanCacheSize});

  int get length => _map.length;

  LogicalPlan? get(String query) {
    final entry = _map[query];
    if (entry == null) return null;
    _moveToFront(entry);
    return entry.plan;
  }

  void put(String query, LogicalPlan plan) {
    final existing = _map[query];
    if (existing != null) {
      existing.plan = plan;
      _moveToFront(existing);
      return;
    }
    final entry = _LruEntry(query, plan);
    _map[query] = entry;
    _insertFront(entry);
    if (_map.length > maxEntries) _evictTail();
  }

  /// Looks up [query] in the cache; if absent, calls [build] and
  /// stores the result. Returns the plan.
  LogicalPlan getOrBuild(String query, LogicalPlan Function() build) {
    final hit = get(query);
    if (hit != null) return hit;
    final plan = build();
    put(query, plan);
    return plan;
  }

  /// Drops every cached entry. Call when the engine's catalog
  /// (interner) changes in a way that would invalidate planned ids.
  void invalidateAll() {
    _map.clear();
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
  }

  void _evictTail() {
    final t = _tail;
    if (t == null) return;
    _unlink(t);
    _map.remove(t.key);
  }
}
