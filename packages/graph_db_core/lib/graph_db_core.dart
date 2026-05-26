/// Core engine of the Flutter-native graph database.
///
/// The public surface is tiered:
///
/// **Stable public API.** What every consumer touches. Breaking these
/// is a major version bump.
///   - [GraphDb] — public façade ([Transaction] handle, primitive
///     range reads, label scans, property accessors)
///   - [Csr] / [PropValue] family / [Vid] / [Eid] / [Durability] /
///     [IsolationLevel] / [LsnPin]
///   - exception hierarchy ([NotFoundException], [ConstraintViolation],
///     …)
///   - [WalOp] hierarchy + [SequencedWalOp]
///   - [ConstraintSpec] hierarchy + [ConstraintCatalog]
///   - [IndexSpec] + [SecondaryIndex] hierarchy
///   - snapshot codec ([encodeSnapshot] / [decodeSnapshot])
///   - identity ([Hlc], [UuidV7])
///
/// **Internal-collaborator surface.** Used by sibling packages
/// (`graph_db_sync`, `graph_db_bench`, the example app) — public to
/// them, but not the recommended path for app authors. Subject to
/// change without a major bump.
///   - [MutableGraphState] (sync engine traverses it; bench / example
///     use `.fromFixture`)
///   - [PropertyStore] (sync engine reads boxed props; example writes
///     directly during bulk-load)
///   - [DeltaOverlay] / [AddedNode] / [AddedEdge] (sync engine reads
///     overlay-added nodes when seeding `fullExport` targets)
///   - [MergeCoordinator] / [IndexRebuildCoordinator] (bench injects
///     for measurement; advanced consumers can opt out of worker-merge)
///   - [BulkEdge] (bulk loaders)
///
/// **Internal-only.** Not exported from this library — visible only
/// within `package:graph_db_core/src/`. Includes: the applicator
/// (`apply()` is called by the WAL replay), the merge protocol
/// (`TransferableCsr` / `TransferableOverlay` / `MergeTask` /
/// `MergeResult`), `foldOverlayIntoCsr`, the persistent-worker
/// scaffolding, `platform.dart` capability flags, and the index
/// worker's task / result types.
library;

// ---------------------------------------------------------- Stable public API
export 'src/constraints/constraint.dart';
export 'src/constraints/constraint_catalog.dart' show ConstraintCatalog;
export 'src/csr.dart';
export 'src/durability.dart';
export 'src/exceptions.dart';
export 'src/graph_db.dart';
export 'src/graph_schema.dart' show GraphSchema;
export 'src/identity/hlc.dart';
export 'src/identity/uuid_v7.dart';
export 'src/ids.dart';
export 'src/isolation.dart';
export 'src/prop_value.dart';
export 'src/read_view.dart' show GraphReadView;
export 'src/secondary_index/index_size_event.dart';
export 'src/secondary_index/index_spec.dart';
export 'src/secondary_index/secondary_index.dart';
export 'src/snapshot/snapshot.dart' show SnapshotMeta, encodeSnapshot, decodeSnapshot;
export 'src/string_interner.dart';
export 'src/transaction.dart' hide markTransactionTerminated;
export 'src/wal_op.dart';
export 'src/wal_sink.dart';

// ---------------------------------------------------- Internal-collaborator
// Exported for sibling packages — not the recommended path for app authors.
// See the library doc above.
export 'src/bulk_edge.dart' show BulkEdge;
export 'src/merge/merge_coordinator.dart' show MergeCoordinator;
export 'src/mutable_graph_state.dart' show MutableGraphState;
export 'src/overlay/delta_overlay.dart'
    show AddedEdge, AddedNode, DeltaOverlay, EdgeDelta, OverlayEdge;
export 'src/property_store.dart' show ColumnType, PropertyStore;
export 'src/secondary_index/index_worker.dart'
    show IndexRebuildCoordinator, buildIntIndexFromSorted;
