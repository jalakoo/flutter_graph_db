/// One remote destination the sync engine ships to.
///
/// A target wraps a [RemoteGraphClient] with the per-destination
/// bookkeeping the engine needs: the high-water-mark LSN it has
/// already shipped past, and a quarantine queue for ops the remote
/// rejected.
library;

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';

/// Mode for the initial sync against a fresh target.
enum SeedingMode {
  /// The target already contains a compatible snapshot of the graph
  /// — start streaming from the current local HWM.
  incremental,

  /// The target is empty (or being re-seeded) — push every node +
  /// edge via `bulkImport` before streaming WAL ops.
  fullExport,
}

/// One rejected op + the reason. Application code reads the
/// [SyncTarget.quarantine] to retry, drop, or surface to the user.
class QuarantinedOp {
  final SequencedWalOp op;
  final RemoteException reason;
  final DateTime rejectedAt;
  const QuarantinedOp({
    required this.op,
    required this.reason,
    required this.rejectedAt,
  });
}

class SyncTarget {
  /// Human-readable identifier — shown in logs + used by tests to
  /// distinguish targets.
  final String name;

  final RemoteGraphClient client;

  /// Initial seeding mode. Once seeded, future syncs are always
  /// incremental.
  final SeedingMode seedingMode;

  /// LSN of the last op successfully shipped + acknowledged by the
  /// remote. v1 keeps this in memory; persistence is the next polish
  /// step (typically alongside engine snapshots — write the HWM into
  /// the snapshot meta so a recovered engine resumes where it left
  /// off).
  int hwm = -1;

  /// Whether the target has been seeded (no-op for [SeedingMode.incremental]).
  bool seeded;

  /// Ops the remote refused to apply.
  final List<QuarantinedOp> quarantine = [];

  SyncTarget({
    required this.name,
    required this.client,
    this.seedingMode = SeedingMode.incremental,
  }) : seeded = seedingMode == SeedingMode.incremental;

  @override
  String toString() =>
      'SyncTarget(name: $name, hwm: $hwm, seeded: $seeded, '
      'quarantined: ${quarantine.length})';
}
