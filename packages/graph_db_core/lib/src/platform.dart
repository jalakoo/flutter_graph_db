/// Platform capability flags, with no Flutter dependency.
///
/// `dart.library.io` is present on the native VM (mobile, desktop,
/// server) and absent on web (dart2js / dart2wasm). On web, real
/// isolates do not exist (`Isolate.spawn` throws) and
/// `TransferableTypedData.fromList` is a no-op wrapper — the spike B
/// findings (§2.3 / §11) gate the worker-merge path on this flag.
library;

/// True on the native VM — real isolates and `TransferableTypedData`
/// move semantics work.
const bool hasNativeIsolates = bool.fromEnvironment('dart.library.io');

/// True on web targets (dart2js / dart2wasm).
const bool isWeb = !hasNativeIsolates;
