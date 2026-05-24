/// WAL schema, encoding, and recovery for the Flutter-native graph DB
///.
///
/// The [WalStore] port and its in-memory adapter live here and
/// are platform-neutral. The native `dart:io` adapter sits behind a
/// separate import (`package:graph_db_wal/io_wal_store.dart`) so a web
/// build of the engine keeps `dart:io` out of its dependency cone.
///
/// The `WalStore` interface + the in-tree adapters live here, plus
/// the [WalCodec] (CBOR + length-prefix framing + xxHash64 checksum)
/// and the thin [WalWriter] / [WalReader] wrappers. Rotated 16 MB
/// segments and the redo-with-commit recovery protocol sit on top.
library;

export 'src/checkpoint.dart' show CheckpointCoordinator, CheckpointPolicy;
export 'src/codec/wal_codec.dart' show WalCodec, WalDecoder;
export 'src/in_memory_snapshot_store.dart' show InMemorySnapshotStore;
export 'src/in_memory_wal_store.dart' show InMemoryWalStore;
export 'src/recovery.dart'
    show
        compactToCurrentTip,
        openWalBackedGraphDb,
        recoverGraphState,
        recoverInto;
export 'src/segmented_in_memory_wal_store.dart'
    show SegmentedInMemoryWalStore, kDefaultWalSegmentBytes;
export 'src/snapshot_store.dart' show SnapshotStore;
export 'src/wal_reader.dart' show WalReader;
export 'src/wal_store.dart' show WalStore;
export 'src/wal_writer.dart' show WalWriter;
