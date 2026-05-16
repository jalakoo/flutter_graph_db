import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Generates a fresh time-ordered UUIDv7 — the conventional
/// `logicalId` for nodes and edges (plan §6.3, §7.4).
///
/// **Across-ms ordering is strict.** The leading 48 bits are
/// big-endian Unix-ms time, so a UUIDv7 produced at a later millisecond
/// always sorts after one produced earlier. That is the property the
/// plan relies on (sortable, time-ordered).
///
/// **Within-ms ordering is implementation-defined.** `package:uuid`'s
/// v7 fills the sub-ms bits with random data, so two ids generated in
/// the same millisecond are NOT ordered relative to each other. The
/// plan does not require within-ms monotonicity — the HLC (`Hlc`)
/// carries causal order for sync.
///
/// Replace with [IdGenerator] in tests that need deterministic ids.
String newUuidV7() => _uuid.v7();

/// Pluggable id source. Production wires [UuidV7Generator]; tests can
/// swap [SequentialIdGenerator] for deterministic logicalIds.
abstract class IdGenerator {
  String next();
}

class UuidV7Generator implements IdGenerator {
  const UuidV7Generator();
  @override
  String next() => newUuidV7();
}

/// Deterministic `prefix-N` id generator — for tests only.
class SequentialIdGenerator implements IdGenerator {
  final String prefix;
  int _n;
  SequentialIdGenerator({this.prefix = 'id-', int start = 0}) : _n = start;
  @override
  String next() => '$prefix${_n++}';
}
