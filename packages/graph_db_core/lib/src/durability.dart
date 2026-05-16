/// Per-commit durability hint (plan §6.7).
///
/// Surfaces through `runInTransaction(durability: …)` (§7.3) and is
/// forwarded to the `WalStore` append path in `graph_db_wal`.
enum Durability {
  /// Hundreds of txn/s. fsync after every commit — single-txn
  /// correctness-critical writes.
  fsync,

  /// Default. Thousands of txn/s. Group-commit window 1ms (configurable).
  group,

  /// Tens of thousands of txn/s. Sync on a periodic timer. Crash window
  /// up to that interval.
  periodic,

  /// RAM speed. No durability guarantee — test fixtures, throwaway
  /// graphs. Crash loses everything in the OS write buffer.
  none,
}
