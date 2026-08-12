/// Persistence port for per-target sync progress.
///
/// Without it the high-water mark lives only in memory, so a restart
/// re-ships the whole retained WAL to every target — correct only if the
/// remote's `bulkImport` happens to be idempotent, and expensive even
/// then. Mirrors the `WalStore` / `SnapshotStore` shape: an abstract port
/// plus an in-memory adapter here, and a `dart:io` adapter behind a
/// separate import so a web build keeps `dart:io` out of its cone.
library;

/// The progress the engine has made against one target.
class SyncTargetState {
  /// LSN of the last op the remote acknowledged. `-1` means "nothing
  /// shipped yet".
  final int hwm;

  /// Whether the initial `fullExport` seed has completed. Meaningless
  /// for `SeedingMode.incremental` targets (always true).
  final bool seeded;

  const SyncTargetState({required this.hwm, required this.seeded});

  Map<String, Object?> toJson() => {'hwm': hwm, 'seeded': seeded};

  static SyncTargetState fromJson(Map<String, Object?> json) =>
      SyncTargetState(
        hwm: json['hwm'] as int? ?? -1,
        seeded: json['seeded'] as bool? ?? false,
      );

  @override
  String toString() => 'SyncTargetState(hwm: $hwm, seeded: $seeded)';

  @override
  bool operator ==(Object other) =>
      other is SyncTargetState && other.hwm == hwm && other.seeded == seeded;

  @override
  int get hashCode => Object.hash(hwm, seeded);
}

/// Durable store for [SyncTargetState], keyed by target name.
abstract class SyncStateStore {
  /// Every persisted target state. Missing targets simply aren't in the
  /// map — the engine leaves those at their in-memory defaults.
  Future<Map<String, SyncTargetState>> readAll();

  /// Records [state] for [targetName]. Must be durable on return: the
  /// engine calls this immediately after a remote acknowledges a batch,
  /// and a lost write means re-shipping that batch after a restart.
  Future<void> write(String targetName, SyncTargetState state);

  /// Forgets [targetName] — used when a target is decommissioned or is
  /// being deliberately re-seeded from scratch.
  Future<void> delete(String targetName);

  Future<void> close();
}

/// Non-durable [SyncStateStore] for tests and for callers that
/// deliberately want re-ship-on-restart behaviour.
class InMemorySyncStateStore implements SyncStateStore {
  final Map<String, SyncTargetState> _states = {};
  bool _closed = false;

  @override
  Future<Map<String, SyncTargetState>> readAll() async {
    _ensureOpen();
    return Map.of(_states);
  }

  @override
  Future<void> write(String targetName, SyncTargetState state) async {
    _ensureOpen();
    _states[targetName] = state;
  }

  @override
  Future<void> delete(String targetName) async {
    _ensureOpen();
    _states.remove(targetName);
  }

  @override
  Future<void> close() async => _closed = true;

  void _ensureOpen() {
    if (_closed) throw StateError('SyncStateStore is closed');
  }
}
