/// Conditional console-warning helper for the sync engine.
///
/// `syncWarn(String)` writes to `stderr` on native and `print` on
/// web (where `dart:io` is unavailable). Used by the
/// `unlabeled_node` fallback path (`5_MULTILABEL_PLAN.md` §19.10.3)
/// and reserved for future sync-side diagnostics.
library;

export '_diag_native.dart'
    if (dart.library.html) '_diag_web.dart'
    if (dart.library.js_interop) '_diag_web.dart';
