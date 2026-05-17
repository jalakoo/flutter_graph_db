/// Engine-side WAL port.
///
/// `graph_db_core` does not depend on `graph_db_wal`. Instead, the
/// engine writes through this abstract sink. `graph_db_wal.WalWriter`
/// implements it; tests can implement it directly with an in-memory
/// collector. `null` on `GraphDb` means in-memory-only operation.
library;

import 'durability.dart';
import 'wal_op.dart';

/// The single port the commit pipeline writes through.
///
/// every [SequencedWalOp] is fed individually with a
/// [Durability] hint; the sink is expected to honour `fsync`
/// synchronously. Group-commit batching may coalesce multiple [append]
/// calls behind a single fsync — the signature stays the same; the
/// *policy* changes at the durability layer.
abstract class WalSink {
  /// Encode + append one sequenced op. Returns once the bytes are
  /// at or past the [durability] level requested.
  Future<void> append(SequencedWalOp op, {required Durability durability});

  /// Encode + append a sequence of ops as a single batch — typically
  /// `BeginTxn` → user ops → `CommitTxn` from one transaction. The
  /// concrete implementation may coalesce the per-op fsync into a
  /// single durability ack (group-commit,). Default impl
  /// loops [append]; concrete writers should override for efficiency.
  Future<void> appendBatch(
    List<SequencedWalOp> ops, {
    required Durability durability,
  }) async {
    for (var i = 0; i < ops.length; i++) {
      final last = i == ops.length - 1;
      // All but the last op append with `none`; the last op carries
      // the requested durability so a single fsync covers the batch.
      await append(
        ops[i],
        durability: last ? durability : Durability.none,
      );
    }
  }

  /// Forces any in-flight bytes to durable storage. Called by
  /// `GraphDb.close()` and by the group-commit timer when batches
  /// close out.
  Future<void> sync();

  /// Releases the sink. After this, [append] / [sync] throw.
  Future<void> close();
}
