/// Secondary-index size-budget event (plan §3.3).
///
/// The soft size budget is a one-shot signal fired at `createIndex()`
/// when the new index's memory footprint exceeds a fraction of the
/// CSR's topology footprint. Default threshold is 25 % (`warn`); the
/// enum reserves higher tiers for forward-compatible escalation
/// **without changing the callback signature** — see §3.3 in the
/// master plan.
library;

import 'index_spec.dart';

/// Index-size warning tier (plan §3.3).
///
/// v1 fires only [warn] (≥ 25 % of CSR). Higher tiers are reserved
/// so that future versions can fire `severe` / `critical` through the
/// same callback without breaking existing listeners.
enum IndexSizeSeverity {
  /// Soft warning — ≥ 25 % of CSR size. v1's only level.
  warn,

  /// Reserved — ≥ 50 % of CSR size. **Not fired in v1.**
  severe,

  /// Reserved — ≥ 75 % of CSR size. **Not fired in v1.**
  critical,
}

/// Event payload passed to `GraphDb.onIndexSizeEvent` (plan §3.3).
///
/// One per `createIndex()` call whose index exceeds the threshold.
/// Library default is silent — the host application opts in by wiring
/// the callback (production logger, telemetry sink, test assertion,
/// etc.).
class IndexSizeEvent {
  /// The spec the user passed to `createIndex`.
  final IndexSpec spec;

  /// Memory the freshly-built index occupies, in bytes.
  final int indexBytes;

  /// CSR (topology) memory, in bytes — the denominator of [ratio].
  final int csrBytes;

  /// `indexBytes / csrBytes`. Convenience — derived from [indexBytes]
  /// and [csrBytes].
  final double ratio;

  /// Which threshold tier fired this event. v1 always [IndexSizeSeverity.warn].
  final IndexSizeSeverity severity;

  const IndexSizeEvent({
    required this.spec,
    required this.indexBytes,
    required this.csrBytes,
    required this.ratio,
    required this.severity,
  });

  @override
  String toString() =>
      'IndexSizeEvent(${spec.name}, '
      '${indexBytes}B / ${csrBytes}B = '
      '${(ratio * 100).toStringAsFixed(1)}%, ${severity.name})';
}

/// Listener type for `GraphDb.onIndexSizeEvent`.
typedef IndexSizeListener = void Function(IndexSizeEvent event);

/// v1 threshold for [IndexSizeSeverity.warn] — 25 % of CSR size per
/// plan §3.3. Higher tiers (`severe` / `critical`) are pre-reserved
/// in the enum but **not fired in v1**.
const double kIndexSizeWarnThreshold = 0.25;
