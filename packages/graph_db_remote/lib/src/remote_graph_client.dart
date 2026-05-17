/// The port adapters implement.
///
/// Concrete adapters live in sibling packages
/// (`graph_db_remote_neo4j`, `graph_db_remote_falkor`) so consumers
/// pull in only the dependencies they need. Application code holds a
/// `RemoteGraphClient` reference; backends are interchangeable behind
/// it.
///
/// The port is intentionally minimal — bulk import / export, query,
/// transaction. Streaming reads (`executeQueryStream`), change
/// subscription (`subscribeChanges`), and health probes are deferred
/// past v1. `tokenProvider` covers v1 auth.
library;

import 'capabilities.dart';
import 'import_export.dart';
import 'result_types.dart';

/// One-shot async function the adapter calls before every request
/// (or once per connection — adapters set the contract). Returns the
/// bearer token / password / API key to put on the wire.
/// — the primary auth mechanism in v1.
typedef TokenProvider = Future<String> Function();

/// Adapter-side transaction handle, returned from
/// `runInTransaction`. Commit + rollback happen automatically when
/// the body returns / throws; the handle is just the namespace for
/// per-txn `executeQuery`.
abstract interface class RemoteTxn {
  /// Runs [query] with [params] inside the transaction. Behaves like
  /// [RemoteGraphClient.executeQuery] but the read/write rows are
  /// scoped to the txn.
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  );
}

abstract interface class RemoteGraphClient {
  /// Capabilities of the wired backend — populated when the adapter
  /// connects.
  CapabilityFlags get capabilities;

  /// Connects to the backend, performs the protocol handshake, and
  /// negotiates [capabilities]. After this resolves, the other
  /// methods are usable.
  Future<void> connect();

  /// Releases the connection + any pooled resources. After this,
  /// every method throws [ConnectionException].
  Future<void> close();

  /// Runs [query] with [params] and materialises the result.
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  );

  /// Runs [body] inside a remote transaction. On normal return the
  /// adapter sends `COMMIT`; on throw it sends `ROLLBACK`. The
  /// `RemoteTxn` passed to [body] is invalid past the function's
  /// return.
  Future<T> runInTransaction<T>(Future<T> Function(RemoteTxn txn) body);

  /// Streams [ops] into the backend's bulk-load endpoint. Adapters
  /// chunk + buffer as appropriate; the stream is consumed once.
  Future<ImportResult> bulkImport(Stream<ImportOp> ops);

  /// Yields every node + edge matching [spec], in backend-defined
  /// order. The element is either a [RemoteNode] or a [RemoteEdge]
  /// — discriminate with `is`.
  Stream<GraphElement> bulkExport(SubgraphSpec spec);
}
