/// Web-only entry point for the IndexedDB-backed `WalStore`
///.
///
/// Consumers opt in:
/// ```dart
/// import 'package:graph_db_wal/indexeddb_wal_store.dart';
///
/// final store = await openIndexedDbWalStore();
/// final db = await openWalBackedGraphDb(store: store);
/// ```
///
/// This file imports `dart:js_interop` + `package:web` and **only**
/// links on the `dart2js` / `dart2wasm` targets. The native umbrella
/// `package:graph_db_wal/graph_db_wal.dart` deliberately does not
/// export it.
library;

export 'src/indexeddb_wal_store.dart'
    show IndexedDbWalStore, openIndexedDbWalStore;
