/// Non-fatal planner observability — surfaces deprecations and other
/// warnings without aborting query execution.
///
/// Mirrors the `onIndexSizeEvent` pattern from
/// `graph_db_core/lib/src/secondary_index/index_size_event.dart`:
/// silent by default, opt-in via a listener on the engine extension.
/// First user: the multi-label rollout PR 3 deprecates `node.label`
/// property access (`5_MULTILABEL_PLAN.md` §19.9 + §12.5). The break
/// is hard at execution time (returns `false` silently on `==
/// 'Person'`); the diagnostic makes it loud at parse/plan time.
library;

enum PlannerDiagnosticSeverity {
  /// Reserved for future informational diagnostics (e.g. unused
  /// alias). Today nothing fires at this level.
  info,

  /// A deprecated syntax that still parses but will be removed.
  warning,
}

class PlannerDiagnostic {
  final PlannerDiagnosticSeverity severity;
  final String message;

  /// Optional suggested rewrite, e.g. `"use labels(n)"`.
  final String? hint;

  /// Optional pointer into the original query text — character
  /// offset, 0-based. Always paired with [hint] when present so the
  /// caller can build an IDE-style diagnostic.
  final int? sourceOffset;

  const PlannerDiagnostic({
    required this.severity,
    required this.message,
    this.hint,
    this.sourceOffset,
  });

  @override
  String toString() {
    final sb = StringBuffer()
      ..write(severity.name.toUpperCase())
      ..write(': ')
      ..write(message);
    if (hint != null) {
      sb
        ..write(' (')
        ..write(hint)
        ..write(')');
    }
    return sb.toString();
  }
}

typedef PlannerDiagnosticListener = void Function(PlannerDiagnostic);
