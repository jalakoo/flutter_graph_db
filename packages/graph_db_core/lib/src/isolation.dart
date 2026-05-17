/// Snapshot isolation primitives (plan §14 Phase 6A / 6B).
///
/// **v1 scope:** the engine is single-writer (plan §2.3), so reads
/// already observe a consistent state between commits — reading
/// after `currentLsn == X` is by definition "all committed ops up to
/// X". The [LsnPin] handle records that observation point so a
/// caller can later compare the engine's `currentLsn` to know
/// whether the engine has advanced past their view.
///
/// **Full MVCC enforcement** — keeping prior CSR versions alive
/// until every pin holding that LSN releases — is documented as the
/// next layer above v1. With the single-writer model + the
/// copy-first merge (Phase 2E), the practical gap is small:
/// readers between merges see a stable CSR; readers across a merge
/// see the post-merge CSR (their pin is *advisory* about what the
/// caller should re-fetch). The pin's `release()` is a hook that
/// future MVCC can latch on to.
library;

/// Read isolation level (plan §14 Phase 6A).
enum IsolationLevel {
  /// Default — reads see the latest committed state. Concurrent
  /// writes may shift the CSR shape mid-read (in practice this
  /// only happens at a merge install, which is itself atomic on
  /// the main isolate).
  readCommitted,

  /// Reader pins the engine's `currentLsn` via [LsnPin]. v1 surfaces
  /// the pin as an observability marker — the engine doesn't yet
  /// hold a prior CSR alive on the reader's behalf (that's the
  /// Phase 6B+ MVCC layer). For single-writer workloads where
  /// reads + writes are interleaved on the same isolate, this is
  /// equivalent to readCommitted.
  snapshot,
}

/// Handle to a captured read-position. Acquired via `GraphDb.pinLsn()`
/// and released via [release]. v1 is a pure observability token —
/// future MVCC enforcement uses the same handle to coordinate
/// version retention.
class LsnPin {
  /// The LSN the pin was captured at.
  final int lsn;
  final IsolationLevel isolation;
  final void Function() _onRelease;
  bool _released = false;

  LsnPin({
    required this.lsn,
    required this.isolation,
    required void Function() onRelease,
  }) : _onRelease = onRelease;

  bool get isReleased => _released;

  /// Releases the pin. Idempotent — calling twice is safe.
  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }

  @override
  String toString() =>
      'LsnPin(lsn: $lsn, isolation: ${isolation.name}, released: $_released)';
}
