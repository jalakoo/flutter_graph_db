import 'dart:typed_data';

/// Port for persisting and loading the engine's compacted-state
/// snapshot — the companion to `WalStore` in the durability story.
///
/// `encodeSnapshot` (in `graph_db_core`) produces the bytes; this port
/// owns *where they live*. Together with `WalStore` it lets the engine
/// checkpoint itself (write a snapshot, then truncate the WAL up to the
/// snapshot's LSN) without the caller hand-rolling file I/O — which is
/// what blocked auto-checkpoint and a one-call durable open.
///
/// **Single-latest semantics.** A store holds at most one snapshot;
/// [write] atomically replaces any prior one. Keep-N retention is a
/// future enhancement and would extend [read] with a selector — the v1
/// shape deliberately stays minimal.
///
/// **Adapters** (mirror the `WalStore` adapter set):
/// - In-memory (`InMemorySnapshotStore`) — tests, and the web fallback.
/// - `dart:io` (`IoSnapshotStore`,
///   `package:graph_db_wal/io_wal_store.dart`, native only) — atomic
///   temp-write + rename.
abstract class SnapshotStore {
  /// Atomically persists [bytes] as the latest snapshot, replacing any
  /// previous one. On return the bytes are durable: a crash after this
  /// completes never leaves a half-written or absent snapshot.
  Future<void> write(Uint8List bytes);

  /// Loads the latest snapshot, or `null` if none has been written yet.
  Future<Uint8List?> read();

  /// Removes the stored snapshot. Idempotent — a no-op if none exists.
  Future<void> delete();

  /// Closes the store. After this, operations throw [StateError].
  Future<void> close();
}
