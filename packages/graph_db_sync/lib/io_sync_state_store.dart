/// `dart:io` file-backed sync-state persistence.
///
/// Native-only (iOS / Android / desktop). Kept out of the main
/// `graph_db_sync.dart` barrel so a web build never pulls `dart:io` into
/// its dependency cone.
library;

export 'src/io_sync_state_store.dart' show IoSyncStateStore;
