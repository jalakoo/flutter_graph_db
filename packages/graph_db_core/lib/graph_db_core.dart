/// Core engine of the Flutter-native graph database (`4_PLAN.md`).
///
/// Public surface for Phase 0 / Phase 1: handle types, the property
/// value boundary hierarchy, exceptions, the storage primitives (CSR,
/// property store, string interner), and the composed
/// [MutableGraphState] read entry point.
///
/// Mutation path, applicator, WAL, GQL, cloud adapters, and sync land
/// in subsequent phases per plan §14.
library;

export 'src/applicator.dart';
export 'src/csr.dart';
export 'src/durability.dart';
export 'src/exceptions.dart';
export 'src/graph_db.dart';
export 'src/identity/hlc.dart';
export 'src/identity/uuid_v7.dart';
export 'src/ids.dart';
export 'src/isolate/persistent_worker.dart';
export 'src/mutable_graph_state.dart';
export 'src/platform.dart';
export 'src/prop_value.dart';
export 'src/property_store.dart';
export 'src/secondary_index/index_size_event.dart';
export 'src/secondary_index/index_spec.dart';
export 'src/secondary_index/secondary_index.dart';
export 'src/string_interner.dart';
export 'src/wal_op.dart';
