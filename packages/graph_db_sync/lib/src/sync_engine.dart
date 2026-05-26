/// Push-only sync engine.
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
///   - HLC + LWW conflict resolution
///   - Opt-in remote-constraint pull
///   - Bi-directional sync (post-v1)
///   - Background timer / change-stream-driven loop (v1 is explicit
///     [syncOnce]; callers schedule it).
library;

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_wal/graph_db_wal.dart';

import '_diag.dart';
import 'sync_target.dart';

/// Substituted for remote `ImportNode.labels` that arrive empty —
/// preserves the local engine's "every node has at least one label"
/// invariant (`5_MULTILABEL_PLAN.md` §4.6). Set
/// `SyncEngine.unlabeledFallback` to override per engine instance;
/// set to `null` to reject empty-label inbound nodes with a
/// `SyncException` instead.
const String kDefaultUnlabeledFallback = 'unlabeled_node';

class SyncException implements Exception {
  final String message;
  SyncException(this.message);
  @override
  String toString() => 'SyncException: $message';
}

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

  /// Label substituted for inbound remote nodes whose label list is
  /// empty. Default `'unlabeled_node'`. Set to a project-specific
  /// label (e.g. `'External'`) to fit your schema; set to `null` to
  /// reject empty-label nodes with a [SyncException] instead. See
  /// `5_MULTILABEL_PLAN.md` §19.10.3.
  String? unlabeledFallback;

  SyncEngine({
    required this.db,
    required this.walStore,
    required this.targets,
    this.importBatchSize = 1024,
    this.unlabeledFallback = kDefaultUnlabeledFallback,
  });

  /// Used by ingest paths that consume `ImportNode.labels` — applies
  /// the [unlabeledFallback] policy and emits the console warning on
  /// substitution. Returns a *non-empty* labels list (or throws).
  List<String> applyUnlabeledFallback(ImportNode op) {
    if (op.labels.isNotEmpty) return op.labels;
    final fb = unlabeledFallback;
    if (fb == null) {
      throw SyncException(
        'remote node "${op.logicalId}" arrived with no labels and '
        'SyncEngine.unlabeledFallback is null',
      );
    }
    syncWarn(
      '[graph_db_sync] WARNING: remote node "${op.logicalId}" had no '
      'labels; substituting fallback label "$fb". Override via '
      'SyncEngine.unlabeledFallback or filter these nodes upstream.',
    );
    return [fb];
  }

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
      final op = _walOpToImport(seq);
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
  /// this is non-disruptive.
  Future<void> _seedTarget(SyncTarget target) async {
    db.mergeNow(); // export against a clean, overlay-empty base
    final view = db.readView;
    final imports = <ImportOp>[];
    // Nodes. After the merge the overlay is empty, so every live node is
    // a base-CSR row reached by index; the logicalId scheme is positional
    // (`local-$v`). (The pre-A1 code also walked overlay-added nodes, but
    // that set is always empty post-merge — dead after the merge above.)
    for (var v = 0; v < db.nodeCount; v++) {
      final vid = Vid(v);
      if (!db.isNodeVisible(vid)) continue;
      imports.add(ImportNode(
        logicalId: 'local-$v',
        labels: _labelsForVid(vid),
        properties: _collectNodeProps(vid),
      ));
    }
    // Edges (overlay is empty post-merge; overlay edges ship via the
    // normal WAL drain).
    for (var v = 0; v < db.nodeCount; v++) {
      final src = Vid(v);
      if (!db.isNodeVisible(src)) continue;
      view.forEachOutNeighbor(src, (dst, eid, typeId) {
        if (!db.isNodeVisible(dst)) return;
        imports.add(ImportEdge(
          logicalId: 'local-e-${eid.value}',
          srcLogicalId: 'local-$v',
          dstLogicalId: 'local-${dst.value}',
          type: db.edgeTypeName(typeId) ?? 'Edge',
          properties: _collectEdgeProps(eid),
        ));
      });
    }
    await target.client.bulkImport(Stream.fromIterable(imports));
    target.seeded = true;
  }

  /// Materialises the multi-label set for [vid] as a sorted list of
  /// label names. Used by the sync seeding loop.
  List<String> _labelsForVid(Vid vid) {
    final out = <String>[
      for (final id in db.labelsOf(vid)) db.labelName(id) ?? '',
    ]..removeWhere((l) => l.isEmpty);
    out.sort();
    return out.isEmpty ? const ['Node'] : out;
  }

  Map<String, PropValue> _namedProps(Map<int, PropValue> props) {
    final out = <String, PropValue>{};
    for (final e in props.entries) {
      final name = db.propKeyName(e.key);
      if (name != null) out[name] = e.value;
    }
    return out;
  }

  // The facade exposes no "every key set on id" iterator — walk the
  // interned propKey space and probe. Fine for small graphs; for large
  // ones the snapshot codec's per-column dump is more efficient (polish).
  Map<String, PropValue> _collectNodeProps(Vid vid) {
    final out = <String, PropValue>{};
    final n = db.propKeyCount;
    for (var k = 0; k < n; k++) {
      if (!db.hasNodeProp(vid, k)) continue;
      final v = db.getNodeProp(vid, k);
      if (v == null) continue;
      final keyName = db.propKeyName(k);
      if (keyName == null) continue;
      out[keyName] = v;
    }
    return out;
  }

  Map<String, PropValue> _collectEdgeProps(Eid eid) {
    final out = <String, PropValue>{};
    final n = db.propKeyCount;
    for (var k = 0; k < n; k++) {
      if (!db.hasEdgeProp(eid, k)) continue;
      final v = db.getEdgeProp(eid, k);
      if (v == null) continue;
      final keyName = db.propKeyName(k);
      if (keyName == null) continue;
      out[keyName] = v;
    }
    return out;
  }

  /// Converts a sequenced WAL op into the adapter-side [ImportOp]
  /// shape. Returns `null` for ops that don't map to a graph
  /// element (BeginTxn / CommitTxn / InternString / constraint ops).
  ImportOp? _walOpToImport(SequencedWalOp seq) {
    final op = seq.op;
    switch (op) {
      case AddNode(:final logicalId, :final labelIds, :final props):
        final labels = <String>[
          for (final id in labelIds) db.labelName(id) ?? '',
        ]..removeWhere((l) => l.isEmpty);
        return ImportNode(
          logicalId: logicalId,
          labels: labels.isEmpty ? const ['Node'] : labels,
          properties: _namedProps(props),
        );
      case AddEdge(
          :final logicalId,
          :final src,
          :final dst,
          :final typeId,
          :final props,
        ):
        final type = db.edgeTypeName(typeId) ?? 'Edge';
        return ImportEdge(
          logicalId: logicalId,
          srcLogicalId: 'local-${src.value}',
          dstLogicalId: 'local-${dst.value}',
          type: type,
          properties: _namedProps(props),
        );
      // DelNode / DelEdge / SetNodeProp / etc. — v1 push-only sync
      // ships them as a future "patch" op shape; for now they're
      // dropped (a later iteration will ship per-op patches).
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
