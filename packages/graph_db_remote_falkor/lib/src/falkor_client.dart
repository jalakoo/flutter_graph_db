/// FalkorDB adapter — implements [RemoteGraphClient] over RESP2.
///
/// FalkorDB extends Redis with the `GRAPH.*` command set. v1 uses
/// `GRAPH.QUERY <graph> <cypher>`; the reply is a nested RESP array
/// in the shape `[headers, records, statistics]`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';

import 'resp/resp.dart';
import 'resp/transport.dart';

class FalkorClientConfig {
  final String host;
  final int port;
  final bool useTls;
  final String graph;
  final String? username;
  final String? password;
  final TokenProvider? tokenProvider;

  const FalkorClientConfig({
    required this.host,
    this.port = 6379,
    this.useTls = false,
    required this.graph,
    this.username,
    this.password,
    this.tokenProvider,
  });
}

class FalkorClient implements RemoteGraphClient {
  final FalkorClientConfig config;
  final Future<RespTransport> Function() _transportFactory;
  RespTransport? _transport;
  StreamSubscription<Uint8List>? _readerSub;
  final RespDecoder _decoder = RespDecoder();
  final List<Completer<Object?>> _pending = [];
  CapabilityFlags _caps = CapabilityFlags.fake;

  FalkorClient(this.config)
      : _transportFactory = (() => SocketRespTransport.connect(
              config.host,
              config.port,
              useTls: config.useTls,
            ));

  /// Test-only — inject a transport factory.
  FalkorClient.withTransport(this.config, this._transportFactory);

  @override
  CapabilityFlags get capabilities => _caps;

  @override
  Future<void> connect() async {
    final transport = await _transportFactory();
    _transport = transport;
    _readerSub = transport.input.listen(_onBytes);
    // AUTH (if credentials supplied)
    final pw = await _resolveCredentials();
    if (pw != null) {
      final ok = await _sendCommand([
        if (config.username == null) 'AUTH' else 'AUTH',
        if (config.username != null) config.username!,
        pw,
      ]);
      if (ok is RespError) {
        await close();
        throw AuthException('FalkorDB AUTH rejected: ${ok.message}');
      }
    }
    // PING for liveness + server hello (no version dance like Bolt).
    final ping = await _sendCommand(['PING']);
    if (ping is RespError) {
      throw ConnectionException('PING failed: ${ping.message}');
    }
    // INFO server → parse version line. Best-effort.
    final info = await _sendCommand(['INFO', 'server']);
    final versionStr = info is String
        ? RegExp(r'redis_version:([^\r\n]+)').firstMatch(info)?.group(1) ??
            'unknown'
        : 'unknown';
    _caps = CapabilityFlags(
      supportsTransactions: false, // FalkorDB Cypher doesn't do BEGIN/COMMIT
      supportsConstraints: true,
      cypherDialect: CypherDialect.falkor,
      maxParameterCount: 0,
      serverVersion: 'FalkorDB (Redis $versionStr)',
    );
  }

  Future<String?> _resolveCredentials() async {
    if (config.tokenProvider != null) return config.tokenProvider!();
    return config.password;
  }

  void _onBytes(Uint8List bytes) {
    _decoder.feed(bytes);
    for (final v in _decoder.pull()) {
      if (_pending.isEmpty) {
        // unsolicited — ignore (no pub/sub in v1)
        continue;
      }
      _pending.removeAt(0).complete(v);
    }
  }

  Future<Object?> _sendCommand(List<String> args) async {
    if (_transport == null) {
      throw const ConnectionException('FalkorDB client is not connected');
    }
    final completer = Completer<Object?>();
    _pending.add(completer);
    await _transport!.write(encodeCommand(args));
    return completer.future;
  }

  @override
  Future<void> close() async {
    await _readerSub?.cancel();
    await _transport?.close();
    _transport = null;
  }

  @override
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  ) async {
    final cypher = params.isEmpty ? query : _inlineParams(query, params);
    final reply = await _sendCommand(['GRAPH.QUERY', config.graph, cypher]);
    if (reply is RespError) {
      throw _mapError(reply);
    }
    // Reply is a nested array: [headers, records, statistics]. The
    // headers list contains [type_id, column_name] pairs.
    if (reply is! List) {
      throw ProtocolException(
          'unexpected GRAPH.QUERY reply: ${reply.runtimeType}');
    }
    if (reply.length < 3) {
      // Statistics-only reply (no result rows — e.g. a write query).
      return const RemoteQueryResult(columns: [], rows: []);
    }
    final headers = (reply[0] as List).cast<List<Object?>>();
    final records = (reply[1] as List).cast<List<Object?>>();
    final columns = [
      for (final h in headers) h[1] as String,
    ];
    final rows = [
      for (final rec in records)
        RemoteRow({
          for (var i = 0; i < columns.length && i < rec.length; i++)
            columns[i]: rec[i],
        }),
    ];
    return RemoteQueryResult(columns: columns, rows: rows);
  }

  /// FalkorDB doesn't support Bolt-style parameter binding via the
  /// wire; the adapter inlines `$key` placeholders. This is best-effort
  /// — strings are quoted + escaped, numbers + bools inlined as-is.
  /// For production-grade parameter safety with arbitrary strings,
  /// callers should pre-sanitise.
  String _inlineParams(String query, Map<String, Object?> params) {
    var out = query;
    for (final e in params.entries) {
      final lit = _toCypherLiteral(e.value);
      out = out.replaceAll('\$${e.key}', lit);
    }
    return out;
  }

  String _toCypherLiteral(Object? v) {
    if (v == null) return 'null';
    if (v is bool) return v ? 'true' : 'false';
    if (v is num) return v.toString();
    if (v is String) return "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
    if (v is List) {
      return '[${v.map(_toCypherLiteral).join(', ')}]';
    }
    if (v is Map) {
      return '{${v.entries.map((e) => '${e.key}: ${_toCypherLiteral(e.value)}').join(', ')}}';
    }
    return "'${v.toString()}'";
  }

  RemoteException _mapError(RespError e) {
    final msg = e.message;
    if (msg.contains('NOAUTH') || msg.contains('WRONGPASS')) {
      return AuthException(msg);
    }
    if (msg.contains('parallel edges') || msg.contains('CONSTRAINT')) {
      return RemoteConstraintViolation(msg);
    }
    if (msg.contains('timed out')) {
      return TimeoutException(msg);
    }
    return ProtocolException(msg);
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function(RemoteTxn) body) async {
    // FalkorDB doesn't expose transactional Cypher in v1 — run the
    // body against a non-isolated session and surface that limit via
    // `capabilities.supportsTransactions == false`.
    final txn = _NonTxn(this);
    return body(txn);
  }

  @override
  Future<ImportResult> bulkImport(Stream<ImportOp> ops) async {
    final sw = Stopwatch()..start();
    var nodes = 0;
    var edges = 0;
    await for (final op in ops) {
      if (op is ImportNode) {
        await executeQuery(
          'CREATE (n:${op.label} {props})',
          {'props': op.properties.map((k, v) => MapEntry(k, _unbox(v)))},
        );
        nodes++;
      } else if (op is ImportEdge) {
        await executeQuery(
          'MATCH (a {logicalId: \$src}), (b {logicalId: \$dst}) '
          'CREATE (a)-[:${op.type} \$p]->(b)',
          {
            'src': op.srcLogicalId,
            'dst': op.dstLogicalId,
            'p': op.properties.map((k, v) => MapEntry(k, _unbox(v))),
          },
        );
        edges++;
      }
    }
    sw.stop();
    return ImportResult(
      nodesImported: nodes,
      edgesImported: edges,
      elapsed: sw.elapsed,
    );
  }

  Object? _unbox(PropValue v) {
    return switch (v) {
      PropInt(:final value) => value,
      PropDouble(:final value) => value,
      PropBool(:final value) => value,
      PropString(:final value) => value,
      PropNull() => null,
      PropList() || PropMap() => null,
    };
  }

  @override
  Stream<GraphElement> bulkExport(SubgraphSpec spec) async* {
    final labelFilter = spec.nodeLabels == null
        ? ''
        : ' WHERE any(l IN labels(n) WHERE l IN ${_toCypherLiteral(spec.nodeLabels)})';
    final nodeQ = 'MATCH (n)$labelFilter RETURN n'
        '${spec.limit == null ? '' : ' LIMIT ${spec.limit}'}';
    final r = await executeQuery(nodeQ, const {});
    for (final row in r.rows) {
      final n = row['n'];
      if (n is RemoteNode) yield n;
    }
  }
}

class _NonTxn implements RemoteTxn {
  final FalkorClient _client;
  _NonTxn(this._client);
  @override
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  ) =>
      _client.executeQuery(query, params);
}
