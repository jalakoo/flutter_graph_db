/// Public exception hierarchy (plan §7.7). Sealed — exhaustive `switch`
/// at any catch boundary.
sealed class GraphDbException implements Exception {
  final String message;
  const GraphDbException(this.message);
  @override
  String toString() => '$runtimeType: $message';
}

/// Retry-eligible — caller may retry the operation.
sealed class TransientException extends GraphDbException {
  const TransientException(super.message);
}

/// Caller fault — retrying without changing the inputs will not help.
sealed class DataException extends GraphDbException {
  const DataException(super.message);
}

/// Engine has detected an unrecoverable problem.
sealed class FatalException extends GraphDbException {
  const FatalException(super.message);
}

// ----- Transient ------------------------------------------------------------

final class IsolationConflict extends TransientException {
  const IsolationConflict(super.message);
}

final class RemoteConflict extends TransientException {
  const RemoteConflict(super.message);
}

final class NetworkException extends TransientException {
  const NetworkException(super.message);
}

// ----- Data -----------------------------------------------------------------

final class ConstraintViolation extends DataException {
  const ConstraintViolation(super.message);
}

final class QuerySyntaxError extends DataException {
  const QuerySyntaxError(super.message);
}

final class NotFoundException extends DataException {
  const NotFoundException(super.message);
}

// ----- Fatal ----------------------------------------------------------------

final class CorruptionDetected extends FatalException {
  const CorruptionDetected(super.message);
}

final class VersionMismatch extends FatalException {
  const VersionMismatch(super.message);
}

final class ConfigurationError extends FatalException {
  const ConfigurationError(super.message);
}
