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

export 'src/csr.dart';
export 'src/exceptions.dart';
export 'src/graph_db.dart';
export 'src/ids.dart';
export 'src/mutable_graph_state.dart';
export 'src/prop_value.dart';
export 'src/property_store.dart';
export 'src/string_interner.dart';
