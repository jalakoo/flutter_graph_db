/// Remote adapter error hierarchy (plan §9).
///
/// Every adapter — Bolt, RESP, future REST / gRPC / etc. — maps its
/// wire-level errors into this hierarchy. Application code catches by
/// `RemoteException` (or a specific subclass) regardless of which
/// backend produced the failure.
library;

/// Base class. All adapter failures derive from this.
sealed class RemoteException implements Exception {
  final String message;
  /// Optional underlying cause from the wire layer (`SocketException`,
  /// `FormatException`, etc.). Adapters set this so callers can drill
  /// in when needed without leaking adapter-specific exception types.
  final Object? cause;

  const RemoteException(this.message, {this.cause});

  @override
  String toString() {
    final base = '${runtimeType.toString()}: $message';
    return cause == null ? base : '$base (cause: $cause)';
  }
}

/// Network-level failure — DNS lookup, TCP connect, TLS handshake,
/// mid-query disconnect.
final class ConnectionException extends RemoteException {
  const ConnectionException(super.message, {super.cause});
}

/// Authentication / authorisation rejected the request.
final class AuthException extends RemoteException {
  const AuthException(super.message, {super.cause});
}

/// Operation took longer than the configured timeout.
final class TimeoutException extends RemoteException {
  const TimeoutException(super.message, {super.cause});
}

/// Backend rejected the operation as constraint-violating — duplicate
/// key, missing required property, schema mismatch, etc. Named
/// `RemoteConstraintViolation` to keep it distinct from the local
/// `graph_db_core.ConstraintViolation`; application code can catch
/// the parent [RemoteException] when the source doesn't matter.
final class RemoteConstraintViolation extends RemoteException {
  const RemoteConstraintViolation(super.message, {super.cause});
}

/// Backend returned a query result that the adapter could not map
/// onto the engine's `PropValue` / `GraphNode` / `GraphEdge` shapes.
/// Distinct from `ConstraintViolation` — this is a serialisation /
/// type mismatch, not a constraint failure.
final class ProtocolException extends RemoteException {
  const ProtocolException(super.message, {super.cause});
}

/// Backend isn't reachable + the adapter has retry / failover policy
/// disabled (or exhausted).
final class UnavailableException extends RemoteException {
  const UnavailableException(super.message, {super.cause});
}

/// The operation isn't supported by this backend. Adapters surface
/// these proactively — e.g. FalkorDB rejecting parallel edges per
/// plan §14 Phase 4 acceptance.
final class UnsupportedOperationException extends RemoteException {
  const UnsupportedOperationException(super.message, {super.cause});
}
