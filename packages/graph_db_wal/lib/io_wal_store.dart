/// Native-only re-export of the `dart:io`-backed [IoWalStore] and
/// [IoSnapshotStore].
///
/// Import this **only** from native targets. The umbrella
/// `package:graph_db_wal/graph_db_wal.dart` deliberately omits it so a
/// web build of the engine keeps `dart:io` out of its dependency cone.
/// Web targets use [InMemoryWalStore] today; an IndexedDB adapter is
/// a future enhancement.
library;

export 'src/io_snapshot_store.dart' show IoSnapshotStore;
export 'src/io_wal_store.dart' show IoWalStore;
