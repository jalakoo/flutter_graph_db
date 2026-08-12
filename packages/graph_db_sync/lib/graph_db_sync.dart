/// Push-only sync engine — consumes the WAL `WalOp` stream and
/// ships transactions to configured `RemoteGraphClient`s.
///
/// The [SyncStateStore] port and its in-memory adapter are
/// platform-neutral and live here. The `dart:io` file adapter sits behind
/// a separate import (`package:graph_db_sync/io_sync_state_store.dart`)
/// so a web build keeps `dart:io` out of its dependency cone.
library;

export 'src/sync_engine.dart'
    show SyncEngine, SyncRunReport, SyncException, kDefaultUnlabeledFallback;
export 'src/sync_state_store.dart'
    show InMemorySyncStateStore, SyncStateStore, SyncTargetState;
export 'src/sync_target.dart'
    show QuarantinedOp, SeedingMode, SyncTarget;
