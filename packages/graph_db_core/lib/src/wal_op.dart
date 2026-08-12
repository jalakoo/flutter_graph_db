import 'ids.dart';
import 'prop_value.dart';
import 'property_store.dart' show ColumnType;
import 'secondary_index/index_spec.dart';
import 'string_interner.dart';

/// One operation in the write-ahead log.
///
/// **Sealed.** The compiler enforces exhaustive `switch` in the
/// applicator, the recovery scan, and any future sync
/// adapter — adding a new operation here is a compile error everywhere
/// it must be handled.
///
/// **Unsequenced.** [WalOp] carries only the *semantic* fields for one
/// operation. The `lsn` + `txnId` assigned at commit time live on the
/// [SequencedWalOp] envelope's sequencing note: *"ops are
/// constructed as an unsequenced form and sealed into WalOp (with
/// lsn/txnId) at commit time."* This split lets transaction code build
/// ops without knowing the LSN yet, and keeps the subclasses immutable
/// and `const`-constructible.
sealed class WalOp {
  const WalOp();
}

/// Marks the start of a transaction's op group.
final class BeginTxn extends WalOp {
  const BeginTxn();
}

/// Marks the end of a transaction's op group. [commitLsn] is the LSN
/// at which the txn becomes durable; recovery applies a `txnId`'s ops
/// only when it has a matching [CommitTxn].
final class CommitTxn extends WalOp {
  final int commitLsn;
  const CommitTxn(this.commitLsn);
}

/// Creates a node at [vid] with [labelIds] and [props].
final class AddNode extends WalOp {
  final Vid vid;
  final String logicalId;
  final List<int> labelIds;
  final Map<int, PropValue> props;
  const AddNode({
    required this.vid,
    required this.logicalId,
    required this.labelIds,
    required this.props,
  });
}

/// Removes a node. Cascade-deletes incident edges within the same
/// transaction.
final class DelNode extends WalOp {
  final Vid vid;
  const DelNode(this.vid);
}

/// Multi-label transition for a node.
final class SetNodeLabels extends WalOp {
  final Vid vid;
  final List<int> added;
  final List<int> removed;
  const SetNodeLabels({
    required this.vid,
    required this.added,
    required this.removed,
  });
}

/// Writes a single node property.
final class SetNodeProp extends WalOp {
  final Vid vid;
  final int keyId;
  final PropValue value;

  /// Optional — carried only when the caller opts in.
  final PropValue? prevValue;

  const SetNodeProp({
    required this.vid,
    required this.keyId,
    required this.value,
    this.prevValue,
  });
}

/// Removes a single node property.
final class DelNodeProp extends WalOp {
  final Vid vid;
  final int keyId;
  const DelNodeProp({required this.vid, required this.keyId});
}

/// Creates an edge between [src] and [dst] with [typeId] and [props].
final class AddEdge extends WalOp {
  final Eid eid;
  final String logicalId;
  final Vid src;
  final Vid dst;
  final int typeId;
  final Map<int, PropValue> props;
  const AddEdge({
    required this.eid,
    required this.logicalId,
    required this.src,
    required this.dst,
    required this.typeId,
    required this.props,
  });
}

/// Removes an edge.
final class DelEdge extends WalOp {
  final Eid eid;
  const DelEdge(this.eid);
}

/// Writes a single edge property.
final class SetEdgeProp extends WalOp {
  final Eid eid;
  final int keyId;
  final PropValue value;
  final PropValue? prevValue;
  const SetEdgeProp({
    required this.eid,
    required this.keyId,
    required this.value,
    this.prevValue,
  });
}

/// Removes a single edge property.
final class DelEdgeProp extends WalOp {
  final Eid eid;
  final int keyId;
  const DelEdgeProp({required this.eid, required this.keyId});
}

/// Constraint kind tag carried by [DeclareConstraint]. v1 ships two
/// kinds; future kinds (FK-like edge type, composite uniques, range
/// constraints) extend the enum.
enum ConstraintKind { unique, existence }

/// Declares a constraint. v1 carries the
/// full spec — name + label + key + kind — so recovery rebuilds the
/// catalog without an out-of-band channel.
final class DeclareConstraint extends WalOp {
  final String name;
  final int labelId;
  final int keyId;
  final ConstraintKind kind;
  const DeclareConstraint({
    required this.name,
    required this.labelId,
    required this.keyId,
    required this.kind,
  });
}

/// Drops a previously declared constraint by name.
final class DropConstraint extends WalOp {
  final String name;
  const DropConstraint({required this.name});
}

/// Which store a schema op targets.
enum PropertyOwner { node, edge }

/// Declares a typed property column ahead of (or alongside) any write.
///
/// Journaled so the column's type-lock survives a restart. Column
/// declarations used to be a purely in-memory side effect, which meant
/// `declareNodeColumn` / `IndexSpec.valueType` had to be repeated on
/// every open or the column silently came back untyped — and a typed
/// read against it threw until the first write re-inferred the type.
final class DeclareColumn extends WalOp {
  final PropertyOwner owner;
  final int keyId;
  final ColumnType type;
  const DeclareColumn({
    required this.owner,
    required this.keyId,
    required this.type,
  });
}

/// Declares a secondary index. Replay re-creates it from the recovered
/// data — the index *contents* are derived, so only the declaration is
/// journaled.
final class DeclareIndex extends WalOp {
  final PropertyOwner owner;
  final IndexSpec spec;
  const DeclareIndex({required this.owner, required this.spec});
}

/// Drops a previously declared index by name. Idempotent.
final class DropIndex extends WalOp {
  final PropertyOwner owner;
  final String name;
  const DropIndex({required this.owner, required this.name});
}

/// Interns a string id for a label / edge type / property key. Replayed
/// during recovery so the local interner agrees with the WAL writer's
/// id assignments.
final class InternString extends WalOp {
  final int intId;
  final String value;
  final StringKind kind;
  const InternString({
    required this.intId,
    required this.value,
    required this.kind,
  });
}

/// A [WalOp] envelope with the `lsn`/`txnId` assigned at commit. The
/// WAL stream and the applicator deal in [SequencedWalOp];
/// transaction-building code constructs the bare [WalOp] payloads first
/// and the commit pipeline seals them.
class SequencedWalOp {
  final int lsn;
  final int txnId;
  final WalOp op;

  const SequencedWalOp({
    required this.lsn,
    required this.txnId,
    required this.op,
  });
}
