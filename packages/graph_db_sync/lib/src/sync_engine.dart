/// Push-only sync engine (plan §10 / §14 Phase 7).
///
/// **v1 scope:**
///   - one-shot drain via [syncOnce] (push the WAL tail past every
///     target's HWM)
///   - per-target HWM (in memory; persistence is a polish item)
///   - quarantine queue for rejected ops
///   - multi-target dispatch
///   - initial seeding via `bulkExport` → `bulkImport`
///
/// **Deferred:**
///   - HLC + LWW conflict resolution (Phase 7E)
///   - Opt-in remote-constraint pull (Phase 7H)
///   - Bi-directional sync (post-v1)
///   - Background timer / change-stream-driven loop (v1 is explicit
///     [syncOnce]; callers schedule it).
library;

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_wal/graph_db_wal.dart';

import 'sync_target.dart';

class SyncRunReport {
  final String targetName;
  final int opsShipped;
  final int opsQuarantined;
  final int previousHwm;
  final int newHwm;
  final bool seededOnThisRun;

  const SyncRunReport({
    required this.targetName,
    required this.opsShipped,
    required this.opsQuarantined,
    required this.previousHwm,
    required this.newHwm,
    required this.seededOnThisRun,
  });

  @override
  String toString() => 'SyncRunReport($targetName: shipped=$opsShipped, '
      'quarantined=$opsQuarantined, hwm=$previousHwm→$newHwm, '
      'seeded=$seededOnThisRun)';
}

class SyncEngine {
  /// The local engine — read source.
  final GraphDb db;

  /// The WAL the engine is writing through. The sync engine reads
  /// from the same store; it replays the committed ops past each
  /// target's HWM and ships them.
  final WalStore walStore;

  /// One or more remote destinations. Sync is push-only; each target
  /// gets the ops independently.
  final List<SyncTarget> targets;

  /// Default batch size for bulk import — concrete adapters may
  /// chunk further. v1 ships all matching ops per target in one
  /// stream call.
  final int importBatchSize;

  SyncEngine({
    required this.db,
    required this.walStore,
    required this.targets,
    this.importBatchSize = 1024,
  });

  /// Drains every committed WAL op past each target's HWM, ships
  /// them via [RemoteGraphClient.bulkImport], and updates the HWM
  /// on success (quarantines on failure). Returns one
  /// [SyncRunReport] per target.
  Future<List<SyncRunReport>> syncOnce() async {
    final reports = <SyncRunReport>[];
    for (final target in targets) {
      reports.add(await _syncTarget(target));
    }
    return reports;
  }

  Future<SyncRunReport> _syncTarget(SyncTarget target) async {
    final previousHwm = target.hwm;
    var seededOnThisRun = false;

    if (!target.seeded && target.seedingMode == SeedingMode.fullExport) {
      await _seedTarget(target);
      seededOnThisRun = true;
      // After a seed, the target is at the current local LSN.
      target.hwm = db.currentLsn;
    }

    // Drain WAL past target.hwm.
    final reader = WalReader(walStore);
    final pending = <ImportOp>[];
    var lastShippableLsn = target.hwm;
    var shipped = 0;
    var quarantined = 0;

    await for (final seq in reader.replay()) {
      if (seq.lsn <= target.hwm) continue;
      final op = _walOpToImport(seq, db.state);
      if (op == null) continue; // not a graph-shaped op (BeginTxn, etc.)
      pending.add(op);
      lastShippableLsn = seq.lsn;
      if (pending.length >= importBatchSize) {
        final ok = await _ship(target, pending, lastShippableLsn, seq);
        if (ok) {
          shipped += pending.length;
        } else {
          quarantined += pending.length;
        }
        pending.clear();
      }
    }
    if (pending.isNotEmpty) {
      // No live SequencedWalOp to attribute the failure to in batch
      // mode — we use the last one as the representative.
      final ok = await _ship(target, pending, lastShippableLsn, null);
      if (ok) {
        shipped += pending.length;
      } else {
        quarantined += pending.length;
      }
      pending.clear();
    }

    return SyncRunReport(
      targetName: target.name,
      opsShipped: shipped,
      opsQuarantined: quarantined,
      previousHwm: previousHwm,
      newHwm: target.hwm,
      seededOnThisRun: seededOnThisRun,
    );
  }

  Future<bool> _ship(
    SyncTarget target,
    List<ImportOp> ops,
    int batchTipLsn,
    SequencedWalOp? exampleSeq,
  ) async {
    try {
      await target.client.bulkImport(Stream.fromIterable(ops));
      target.hwm = batchTipLsn;
      return true;
    } on RemoteException catch (e) {
      // Quarantine the whole batch — v1 is coarse-grained. Polish
      // step: split the batch + retry the survivors.
      final representative = exampleSeq ??
          SequencedWalOp(
            lsn: batchTipLsn,
            txnId: -1,
            op: const BeginTxn(),
          );
      target.quarantine.add(QuarantinedOp(
        op: representative,
        reason: e,
        rejectedAt: DateTime.now(),
      ));
      return false;
    }
  }

  /// Initial full-graph push for [SeedingMode.fullExport] targets.
  ///
  /// Merges the overlay into the CSR first so the iteration sees a
  /// clean base; the overlay represents already-committed state, so
  /// this is non-disruptive (Phase 2E merge semantics).
  Future<void> _seedTarget(SyncTarget target) async {
    db.state.mergeNow();
    final imports = <ImportOp>[];
    // Nodes
    for (var v = 0; v < db.state.csr.nodeCount; v++) {
      if (!db.state.isNodeVisible(Vid(v))) continue;
      final addedNode = db.state.overlay.addedNodes[v];
      final logicalId = addedNode?.logicalId ?? 'local-$v';
      final labelId = db.state.effectiveLabelOf(Vid(v));
      final label = db.state.strings.labelOf(labelId) ?? 'Node';
      imports.add(ImportNode(
        logicalId: logicalId,
        label: label,
        properties: _collectProps(db.state.nodeProps, v),
      ));
    }
    for (final entry in db.state.overlay.addedNodes.entries) {
      final v = entry.key;
      if (!db.state.isNodeVisible(Vid(v))) continue;
      final labelId = entry.value.labelIds.isEmpty ? 0 : entry.value.labelIds.first;
      final label = db.state.strings.labelOf(labelId) ?? 'Node';
      imports.add(ImportNode(
        logicalId: entry.value.logicalId,
        label: label,
        properties: _collectProps(db.state.nodeProps, v),
      ));
    }
    // Edges (CSR base only — overlay edges are part of the WAL tail
    // and get shipped via the normal drain).
    final csr = db.state.csr;
    for (var v = 0; v < csr.nodeCount; v++) {
      if (!db.state.isNodeVisible(Vid(v))) continue;
      final end = csr.rowPtrOut[v + 1];
      for (var i = csr.rowPtrOut[v]; i < end; i++) {
        final eid = csr.edgeIdOut[i];
        final dst = csr.colIdxOut[i];
        if (!db.state.isNodeVisible(Vid(dst))) continue;
        final typeId = csr.edgeTypeOut[i];
        final type = db.state.strings.edgeTypeOf(typeId) ?? 'Edge';
        imports.add(ImportEdge(
          logicalId: 'local-e-$eid',
          srcLogicalId: 'local-$v',
          dstLogicalId: 'local-$dst',
          type: type,
          properties: _collectProps(db.state.edgeProps, eid),
        ));
      }
    }
    await target.client.bulkImport(Stream.fromIterable(imports));
    target.seeded = true;
  }

  Map<String, PropValue> _namedProps(
    Map<int, PropValue> props,
    MutableGraphState state,
  ) {
    final out = <String, PropValue>{};
    for (final e in props.entries) {
      final name = state.strings.propKeyOf(e.key);
      if (name != null) out[name] = e.value;
    }
    return out;
  }

  Map<String, PropValue> _collectProps(PropertyStore store, int id) {
    final out = <String, PropValue>{};
    // PropertyStore doesn't expose a "every key set on id" iterator
    // — walk the interner's propKey space and probe. v1 is fine
    // for small graphs; for large graphs the snapshot codec's per-
    // column dump pattern is more efficient (polish item).
    final n = db.state.strings.propKeyCount;
    for (var k = 0; k < n; k++) {
      if (!store.has(id, k)) continue;
      final v = store.getBoxed(id, k);
      if (v == null) continue;
      final keyName = db.state.strings.propKeyOf(k);
      if (keyName == null) continue;
      out[keyName] = v;
    }
    return out;
  }

  /// Converts a sequenced WAL op into the adapter-side [ImportOp]
  /// shape. Returns `null` for ops that don't map to a graph
  /// element (BeginTxn / CommitTxn / InternString / constraint ops).
  ImportOp? _walOpToImport(SequencedWalOp seq, MutableGraphState state) {
    final op = seq.op;
    switch (op) {
      case AddNode(:final logicalId, :final labelIds, :final props):
        final labelName = labelIds.isEmpty
            ? 'Node'
            : (state.strings.labelOf(labelIds.first) ?? 'Node');
        return ImportNode(
          logicalId: logicalId,
          label: labelName,
          properties: _namedProps(props, state),
        );
      case AddEdge(
          :final logicalId,
          :final src,
          :final dst,
          :final typeId,
          :final props,
        ):
        final type = state.strings.edgeTypeOf(typeId) ?? 'Edge';
        return ImportEdge(
          logicalId: logicalId,
          srcLogicalId: 'local-${src.value}',
          dstLogicalId: 'local-${dst.value}',
          type: type,
          properties: _namedProps(props, state),
        );
      // DelNode / DelEdge / SetNodeProp / etc. — v1 push-only sync
      // ships them as a future "patch" op shape; for now they're
      // dropped (full Phase 7B+ ships per-op patches).
      case DelNode():
      case DelEdge():
      case SetNodeProp():
      case DelNodeProp():
      case SetEdgeProp():
      case DelEdgeProp():
      case SetNodeLabels():
      case BeginTxn():
      case CommitTxn():
      case InternString():
      case DeclareConstraint():
      case DropConstraint():
        return null;
    }
  }
}
