/// Worker-isolate merge coordinator (plan §2.3 / §14 Phase 2 polish).
///
/// Owns one [PersistentWorker] for the lifetime of the engine. The
/// main isolate **copies** the CSR + overlay into transferable
/// buffers, hands them off to the worker, awaits the merged CSR. The
/// live CSR is never detached — reads continue against it during the
/// merge.
///
/// On web (where `Isolate.spawn` throws), the coordinator's web
/// fallback folds inline on the main isolate. This violates the
/// `< 1 ms` stall acceptance target on web — a documented Phase 8
/// concern.
library;

import 'dart:isolate';

import '../csr.dart';
import '../isolate/persistent_worker.dart';
import '../overlay/delta_overlay.dart';
import 'merge_fold.dart';
import 'merge_protocol.dart';

/// Top-level worker entry. Must be top-level (not a closure) so
/// `Isolate.spawn` can serialize it.
void mergeWorkerEntry(SendPort handshake) {
  runPersistentWorkerLoop<MergeTask, MergeResult>(handshake, _doMergeOnWorker);
}

MergeResult _doMergeOnWorker(MergeTask task) {
  final sw = Stopwatch()..start();
  final base = task.csr.materialize();
  final overlay = task.overlay.materialize();
  final fresh = foldOverlayIntoCsr(base: base, overlay: overlay);
  sw.stop();
  return MergeResult(
    csr: TransferableCsr.copyAndWrap(fresh),
    computeUs: sw.elapsedMicroseconds,
  );
}

/// Web-only fallback handler — runs inline on the main isolate.
MergeResult _doMergeWebFallback(MergeTask task) {
  // On web the wrap was a no-op pass-through; the buffers are still
  // sharable. We still go through materialize → fold → wrap so the
  // call shape matches the native path.
  return _doMergeOnWorker(task);
}

class MergeCoordinator {
  final PersistentWorker<MergeTask, MergeResult> _worker;
  /// Wall time of the most recent merge (us). Useful for tests + bench.
  int lastMergeWorkerUs = 0;

  MergeCoordinator._(this._worker);

  /// Spawns the worker isolate (or, on web, builds a main-isolate
  /// fallback). Returns a ready-to-use coordinator.
  static Future<MergeCoordinator> spawn() async {
    final worker = await PersistentWorker.spawn<MergeTask, MergeResult>(
      mergeWorkerEntry,
      webFallback: _doMergeWebFallback,
    );
    return MergeCoordinator._(worker);
  }

  /// True when a real worker isolate is in use (native targets).
  bool get usesIsolate => _worker.usesIsolate;

  /// Folds [overlay] into [base] off-main and returns the new CSR.
  /// The main isolate pays only the copy cost; the fold runs in the
  /// worker. Caller installs the returned CSR via
  /// `MutableGraphState.installMergedCsr`.
  Future<Csr> merge(Csr base, DeltaOverlay overlay) async {
    final task = MergeTask(
      csr: TransferableCsr.copyAndWrap(base),
      overlay: TransferableOverlay.copyAndWrap(overlay),
    );
    final result = await _worker.send(task);
    lastMergeWorkerUs = result.computeUs;
    return result.csr.materialize();
  }

  Future<void> dispose() => _worker.dispose();
}
