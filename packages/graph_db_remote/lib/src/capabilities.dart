/// Adapter capability flags.
///
/// Backend-specific behaviour flows through this surface — application
/// code stays backend-agnostic but can branch on capability bits when
/// it really needs to.
library;

/// Which Cypher dialect the backend speaks. Engines / adapters set
/// this; the GQL layer may use it to enable / disable specific
/// translations.
enum CypherDialect { neo4j, falkor, opencypher, none }

class CapabilityFlags {
  /// Backend supports `BEGIN` / `COMMIT` transactional semantics
  /// (Neo4j: yes; many embedded engines: yes; FalkorDB: read-only
  /// txns in newer versions).
  final bool supportsTransactions;

  /// Backend can enforce uniqueness / existence constraints on
  /// `(label, property)` pairs.
  final bool supportsConstraints;

  /// The Cypher dialect spoken by the backend, useful when an
  /// adapter or the GQL layer wants to translate a v1 OpenCypher
  /// query into a dialect-specific form.
  final CypherDialect cypherDialect;

  /// Per `executeQuery` parameter limit. `0` means unbounded; the
  /// adapter MUST surface this even if the backend has no hard limit
  /// (a generous default) so callers can pre-flight large requests.
  final int maxParameterCount;

  /// Backend version string as reported by the wire handshake (e.g.
  /// `'Neo4j/5.21.0'`). Adapters set this on connect.
  final String serverVersion;

  const CapabilityFlags({
    required this.supportsTransactions,
    required this.supportsConstraints,
    required this.cypherDialect,
    required this.maxParameterCount,
    required this.serverVersion,
  });

  /// Capabilities reported by the in-memory test fake — every flag
  /// off, generic dialect, unbounded params.
  static const CapabilityFlags fake = CapabilityFlags(
    supportsTransactions: false,
    supportsConstraints: false,
    cypherDialect: CypherDialect.none,
    maxParameterCount: 0,
    serverVersion: 'fake',
  );

  @override
  String toString() => 'CapabilityFlags('
      'tx=$supportsTransactions, '
      'constraints=$supportsConstraints, '
      'dialect=${cypherDialect.name}, '
      'maxParams=$maxParameterCount, '
      'server="$serverVersion")';
}
