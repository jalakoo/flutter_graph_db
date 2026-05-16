/// WAL schema, encoding, and recovery for the Flutter-native graph DB
/// (plan §6).
///
/// The [WalStore] port (§2.2) and its in-memory adapter live here and
/// are platform-neutral. The native `dart:io` adapter sits behind a
/// separate import (`package:graph_db_wal/io_wal_store.dart`) so a web
/// build of the engine keeps `dart:io` out of its dependency cone.
///
/// **Phase 0 — skeleton.** The `WalStore` interface + the two in-tree
/// adapters land here, plus the [WalCodec] (CBOR + length-prefix
/// framing + xxHash64 checksum per §6.1) and the thin [WalWriter] /
/// [WalReader] wrappers. Rotated 16 MB segments (§6.2), the
/// redo-with-commit recovery protocol on top of the reader (§6.5),
/// and hand-rolled encoders for the three hot [WalOp] shapes (per the
/// §13 audit) are scheduled for Phase 2 per plan §14.
library;

export 'src/codec/wal_codec.dart' show WalCodec, WalDecoder;
export 'src/in_memory_wal_store.dart' show InMemoryWalStore;
export 'src/wal_reader.dart' show WalReader;
export 'src/wal_store.dart' show WalStore;
export 'src/wal_writer.dart' show WalWriter;
