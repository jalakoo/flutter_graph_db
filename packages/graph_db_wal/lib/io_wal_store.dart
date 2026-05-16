/// Native-only re-export of the `dart:io`-backed [IoWalStore].
///
/// Import this **only** from native targets. The umbrella
/// `package:graph_db_wal/graph_db_wal.dart` deliberately omits it so a
/// web build of the engine keeps `dart:io` out of its dependency cone
/// (plan §2.2). Web targets use [InMemoryWalStore] today; the
/// IndexedDB adapter lands in Phase 8.
library;

export 'src/io_wal_store.dart' show IoWalStore;
