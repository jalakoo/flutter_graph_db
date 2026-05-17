/// Worker-isolate index rebuild.
///
/// Mirrors `merge/merge_coordinator.dart` (the copy-first
/// design): main isolate **copies** the column's (value, vid) pairs
/// into fresh typed buffers, wraps them in [TransferableTypedData],
/// sends to a worker; worker sorts + packs the result and returns;
/// main installs. The live property store is never detached.
///
/// **Scope:** supports `int_` (`Float64List` value column — web
/// compat) only. The same pattern extends trivially to `double_` /
/// `stringId` / `bool` (uniform typed-list shape); the `string`
/// column needs a different transport (strings travel as
/// `List<String>` across isolates).
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../isolate/persistent_worker.dart';
import 'index_spec.dart';
import 'secondary_index.dart';

class IndexRebuildIntTask {
  final IndexSpec spec;
  final bool hashOverlay;
  final TransferableTypedData values; // Float64List copy (ints as doubles)
  final TransferableTypedData vids; // Uint32List copy
  IndexRebuildIntTask({
    required this.spec,
    required this.hashOverlay,
    required this.values,
    required this.vids,
  });

  factory IndexRebuildIntTask.copyAndWrap({
    required IndexSpec spec,
    required bool hashOverlay,
    required Float64List values,
    required Uint32List vids,
  }) =>
      IndexRebuildIntTask(
        spec: spec,
        hashOverlay: hashOverlay,
        values: TransferableTypedData.fromList([Float64List.fromList(values)]),
        vids: TransferableTypedData.fromList([Uint32List.fromList(vids)]),
      );
}

class IndexRebuildIntResult {
  final IndexSpec spec;
  final bool hashOverlay;
  final TransferableTypedData sortedValues;
  final TransferableTypedData sortedVids;
  final int sortUs;
  IndexRebuildIntResult({
    required this.spec,
    required this.hashOverlay,
    required this.sortedValues,
    required this.sortedVids,
    required this.sortUs,
  });
}

/// Top-level worker entry (required for `Isolate.spawn`).
void indexWorkerEntry(SendPort handshake) {
  runPersistentWorkerLoop<IndexRebuildIntTask, IndexRebuildIntResult>(
    handshake,
    _doRebuildInt,
  );
}

IndexRebuildIntResult _doRebuildInt(IndexRebuildIntTask task) {
  final sw = Stopwatch()..start();
  final values = task.values.materialize().asFloat64List();
  final vids = task.vids.materialize().asUint32List();
  final n = values.length;
  // Sort by (value, vid) — match the build factory's ordering so the
  // installed result is byte-identical to a fresh rebuild.
  final pairs = List<int>.generate(n, (i) => i)
    ..sort((a, b) {
      final c = values[a].compareTo(values[b]);
      return c != 0 ? c : vids[a].compareTo(vids[b]);
    });
  final sortedValues = Float64List(n);
  final sortedVids = Uint32List(n);
  for (var i = 0; i < n; i++) {
    sortedValues[i] = values[pairs[i]];
    sortedVids[i] = vids[pairs[i]];
  }
  sw.stop();
  return IndexRebuildIntResult(
    spec: task.spec,
    hashOverlay: task.hashOverlay,
    sortedValues:
        TransferableTypedData.fromList([sortedValues]),
    sortedVids: TransferableTypedData.fromList([sortedVids]),
    sortUs: sw.elapsedMicroseconds,
  );
}

/// Coordinator — owns one worker for the lifetime of the engine.
class IndexRebuildCoordinator {
  final PersistentWorker<IndexRebuildIntTask, IndexRebuildIntResult> _worker;
  int lastWorkerUs = 0;
  IndexRebuildCoordinator._(this._worker);

  static Future<IndexRebuildCoordinator> spawn() async {
    final w = await PersistentWorker
        .spawn<IndexRebuildIntTask, IndexRebuildIntResult>(
      indexWorkerEntry,
      webFallback: _doRebuildInt,
    );
    return IndexRebuildCoordinator._(w);
  }

  bool get usesIsolate => _worker.usesIsolate;

  /// Sends the task, awaits the worker's result, materialises the
  /// sorted arrays on the main isolate. The CALLER is responsible
  /// for installing the rebuilt index into the registry — this
  /// method just produces the typed arrays.
  Future<({Float64List sortedValues, Uint32List sortedVids})> rebuildInt(
    IndexRebuildIntTask task,
  ) async {
    final result = await _worker.send(task);
    lastWorkerUs = result.sortUs;
    return (
      sortedValues: result.sortedValues.materialize().asFloat64List(),
      sortedVids: result.sortedVids.materialize().asUint32List(),
    );
  }

  Future<void> dispose() => _worker.dispose();
}

/// Helper — snapshots an `IntEqualityRangeIndex`-eligible column on
/// the main isolate (into fresh typed buffers ready for transfer).
/// Caller passes the result to [IndexRebuildCoordinator.rebuildInt].
({Float64List values, Uint32List vids}) snapshotIntColumn({
  required Iterable<(int vid, int value)> pairs,
}) {
  final list = pairs.toList(growable: false);
  final values = Float64List(list.length);
  final vids = Uint32List(list.length);
  for (var i = 0; i < list.length; i++) {
    values[i] = list[i].$2.toDouble();
    vids[i] = list[i].$1;
  }
  return (values: values, vids: vids);
}

/// Builder — assembles an `IntEqualityRangeIndex` from the worker's
/// already-sorted typed arrays. Used by the install path so the
/// resulting index is byte-identical to the synchronous build.
IntEqualityRangeIndex buildIntIndexFromSorted({
  required IndexSpec spec,
  required Float64List sortedValues,
  required Uint32List sortedVids,
  required bool hashOverlay,
}) {
  Map<int, Uint32List>? hash;
  if (hashOverlay) {
    final tmp = <int, List<int>>{};
    for (var i = 0; i < sortedValues.length; i++) {
      (tmp[sortedValues[i].toInt()] ??= <int>[]).add(sortedVids[i]);
    }
    hash = {for (final e in tmp.entries) e.key: Uint32List.fromList(e.value)};
  }
  return IntEqualityRangeIndex.fromSorted(
    spec: spec,
    sortedValues: sortedValues,
    sortedVids: sortedVids,
    hash: hash,
  );
}
