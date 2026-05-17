/// Push-only sync engine — consumes the WAL `WalOp` stream and
/// ships transactions to configured `RemoteGraphClient`s (plan §10 /
/// §14 Phase 7).
library;

export 'src/sync_engine.dart' show SyncEngine, SyncRunReport;
export 'src/sync_target.dart'
    show QuarantinedOp, SeedingMode, SyncTarget;
