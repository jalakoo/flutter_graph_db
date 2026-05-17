/// Neo4j adapter — implements [RemoteGraphClient] over Bolt v4/v5.
library;

import 'dart:async';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';

import 'bolt/connection.dart';
import 'bolt/messages.dart';
import 'bolt/packstream.dart';
import 'bolt/transport.dart';

class Neo4jClientConfig {
  final String host;
  final int port;
  final bool useTls;
  final String? username;
  final String? password;
  /// Future-bearing token provider. Takes precedence over
  /// [password] if both are set.
  final TokenProvider? tokenProvider;
  final String userAgent;

  const Neo4jClientConfig({
    required this.host,
    this.port = 7687,
    this.useTls = false,
    this.username,
    this.password,
    this.tokenProvider,
    this.userAgent = 'flutter_graph_db/0.1',
  });
}

class Neo4jClient implements RemoteGraphClient {
  final Neo4jClientConfig config;
  final Future<BoltTransport> Function() _transportFactory;
  BoltConnection? _conn;
  CapabilityFlags _caps = CapabilityFlags.fake;

  Neo4jClient(this.config)
      : _transportFactory = (() => SocketBoltTransport.connect(
              config.host,
              config.port,
              useTls: config.useTls,
            ));

  /// Test-only — inject a transport factory (mock socket). Production
  /// callers use the public constructor.
  Neo4jClient.withTransport(this.config, this._transportFactory);

  @override
  CapabilityFlags get capabilities => _caps;

  @override
  Future<void> connect() async {
    final transport = await _transportFactory();
    final conn = BoltConnection(transport);
    final version = await conn.handshake();
    // HELLO
    final pw = await _resolveCredentials();
    await conn.send(buildHello(
      userAgent: config.userAgent,
      scheme: config.username == null ? 'none' : 'basic',
      principal: config.username ?? '',
      credentials: pw ?? '',
    ));
    final reply = await conn.receive();
    if (reply.tag != BoltMessage.success) {
      await transport.close();
      throw AuthException(
        'Neo4j HELLO rejected: ${_describe(reply)}',
      );
    }
    _conn = conn;
    final meta = reply.fields.isEmpty ? const <String, Object?>{} : reply.fields.first as Map<String, Object?>;
    final serverName = (meta['server'] as String?) ?? 'Neo4j/unknown';
    _caps = CapabilityFlags(
      supportsTransactions: true,
      supportsConstraints: true,
      cypherDialect: CypherDialect.neo4j,
      maxParameterCount: 0, // Neo4j doesn't advertise a hard cap
      serverVersion: '$serverName (Bolt ${version.major}.${version.minor})',
    );
  }

  Future<String?> _resolveCredentials() async {
    if (config.tokenProvider != null) return config.tokenProvider!();
    return config.password;
  }

  @override
  Future<void> close() async {
    if (_conn != null) {
      await _conn!.close();
      _conn = null;
    }
  }

  @override
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  ) =>
      _runAndPull(_requireConn(), query, params);

  Future<RemoteQueryResult> _runAndPull(
    BoltConnection conn,
    String query,
    Map<String, Object?> params,
  ) async {
    await conn.send(buildRun(query, params));
    final runReply = await conn.receive();
    if (runReply.tag == BoltMessage.failure) {
      await _resetAfterFailure(conn);
      throw _failureToException(runReply);
    }
    final runMeta = runReply.fields.isEmpty
        ? const <String, Object?>{}
        : runReply.fields.first as Map<String, Object?>;
    final columns =
        (runMeta['fields'] as List?)?.cast<String>() ?? const <String>[];
    await conn.send(buildPull());
    final rows = <RemoteRow>[];
    while (true) {
      final r = await conn.receive();
      if (r.tag == BoltMessage.record) {
        final values = r.fields.single as List<Object?>;
        final out = <String, Object?>{};
        for (var i = 0; i < columns.length && i < values.length; i++) {
          out[columns[i]] = _toBoundary(values[i]);
        }
        rows.add(RemoteRow(out));
      } else if (r.tag == BoltMessage.success) {
        break;
      } else if (r.tag == BoltMessage.failure) {
        await _resetAfterFailure(conn);
        throw _failureToException(r);
      } else {
        throw ProtocolException('unexpected Bolt message tag '
            '0x${r.tag.toRadixString(16)}');
      }
    }
    return RemoteQueryResult(columns: columns, rows: rows);
  }

  Future<void> _resetAfterFailure(BoltConnection conn) async {
    await conn.send(BoltStruct(BoltMessage.reset, const []));
    // drain the SUCCESS / IGNORED for the reset
    try {
      await conn.receive();
    } catch (_) {/* best-effort */}
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function(RemoteTxn txn) body) async {
    final conn = _requireConn();
    await conn.send(buildBegin());
    final beginReply = await conn.receive();
    if (beginReply.tag != BoltMessage.success) {
      throw _failureToException(beginReply);
    }
    final txn = _BoltTxn(conn, this);
    try {
      final result = await body(txn);
      await conn.send(buildCommit());
      final commitReply = await conn.receive();
      if (commitReply.tag != BoltMessage.success) {
        throw _failureToException(commitReply);
      }
      return result;
    } catch (_) {
      try {
        await conn.send(buildRollback());
        await conn.receive();
      } catch (_) {/* best-effort */}
      rethrow;
    }
  }

  @override
  Future<ImportResult> bulkImport(Stream<ImportOp> ops) async {
    final sw = Stopwatch()..start();
    var nodes = 0;
    var edges = 0;
    await for (final op in ops) {
      if (op is ImportNode) {
        await executeQuery(
          'CREATE (n:${op.label} \$p)',
          {'p': _propMapToCypher(op.properties)},
        );
        nodes++;
      } else if (op is ImportEdge) {
        await executeQuery(
          'MATCH (a {logicalId: \$src}), (b {logicalId: \$dst}) '
          'CREATE (a)-[:${op.type} \$p]->(b)',
          {
            'src': op.srcLogicalId,
            'dst': op.dstLogicalId,
            'p': _propMapToCypher(op.properties),
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

  @override
  Stream<GraphElement> bulkExport(SubgraphSpec spec) async* {
    // Minimal — full bulk-export is a follow-up. Emit nodes
    // first, then edges, both filtered by spec.
    final labelFilter = spec.nodeLabels == null
        ? ''
        : ' WHERE any(l IN labels(n) WHERE l IN \$labels)';
    final nodeQ = 'MATCH (n)$labelFilter RETURN n'
        '${spec.limit == null ? '' : ' LIMIT ${spec.limit}'}';
    final nodeR = await executeQuery(nodeQ, {
      if (spec.nodeLabels != null) 'labels': spec.nodeLabels,
    });
    for (final row in nodeR.rows) {
      final n = row['n'];
      if (n is RemoteNode) yield n;
    }
    final typeFilter = spec.edgeTypes == null
        ? ''
        : ' WHERE type(r) IN \$types';
    final edgeQ = 'MATCH ()-[r]->()$typeFilter RETURN r'
        '${spec.limit == null ? '' : ' LIMIT ${spec.limit}'}';
    final edgeR = await executeQuery(edgeQ, {
      if (spec.edgeTypes != null) 'types': spec.edgeTypes,
    });
    for (final row in edgeR.rows) {
      final r = row['r'];
      if (r is RemoteEdge) yield r;
    }
  }

  BoltConnection _requireConn() {
    final c = _conn;
    if (c == null) throw const ConnectionException('Neo4j client is not connected');
    return c;
  }

  /// Walks a Bolt-decoded value tree and lifts Node/Rel/Path structs
  /// into engine-side `RemoteNode` / `RemoteEdge` / `RemotePath`.
  Object? _toBoundary(Object? v) {
    if (v is BoltStruct) {
      switch (v.tag) {
        case boltNodeTag:
          // Bolt v4: fields = [id (int), labels (list<string>), props (map)]
          // Bolt v5: fields = [..., elementId (string)]
          final id = v.fields[0];
          final labels = (v.fields[1] as List).cast<String>();
          final props = (v.fields[2] as Map).cast<String, Object?>();
          return RemoteNode(
            logicalId: (props['logicalId'] as String?) ?? '$id',
            label: labels.isEmpty ? null : labels.first,
            properties: _propsToBoundary(props),
            remoteId: id.toString(),
          );
        case boltRelTag:
          // fields = [id, srcId, dstId, type, props, (elementId, srcElementId, dstElementId)]
          final id = v.fields[0];
          final srcId = v.fields[1];
          final dstId = v.fields[2];
          final type = v.fields[3] as String;
          final props = (v.fields[4] as Map).cast<String, Object?>();
          return RemoteEdge(
            logicalId: (props['logicalId'] as String?) ?? '$id',
            type: type,
            srcLogicalId: '$srcId',
            dstLogicalId: '$dstId',
            properties: _propsToBoundary(props),
            remoteId: id.toString(),
          );
        case boltPathTag:
          // fields = [nodes (list), rels (list), indices (list<int>)]
          final nodes = (v.fields[0] as List).map(_toBoundary).whereType<RemoteNode>().toList();
          final rels = (v.fields[1] as List).map(_toBoundary).whereType<RemoteEdge>().toList();
          return RemotePath(nodes: nodes, edges: rels);
      }
    }
    if (v is List) return v.map(_toBoundary).toList();
    if (v is Map) {
      return {for (final e in v.entries) e.key.toString(): _toBoundary(e.value)};
    }
    return v;
  }

  Map<String, PropValue> _propsToBoundary(Map<String, Object?> props) {
    final out = <String, PropValue>{};
    for (final e in props.entries) {
      final v = e.value;
      if (v == null) {
        out[e.key] = const PropNull();
      } else if (v is bool) {
        out[e.key] = PropBool(v);
      } else if (v is int) {
        out[e.key] = PropInt(v);
      } else if (v is double) {
        out[e.key] = PropDouble(v);
      } else if (v is String) {
        out[e.key] = PropString(v);
      }
      // lists / maps / nested types: skip in v1 (PropList / PropMap
      // round-trip is a follow-up).
    }
    return out;
  }

  /// Converts a PropValue map back to Cypher-friendly Dart for `$p`
  /// parameter binding on `bulkImport`.
  Map<String, Object?> _propMapToCypher(Map<String, PropValue> props) {
    final out = <String, Object?>{};
    for (final e in props.entries) {
      final v = e.value;
      switch (v) {
        case PropNull():
          out[e.key] = null;
        case PropInt(:final value):
          out[e.key] = value;
        case PropDouble(:final value):
          out[e.key] = value;
        case PropBool(:final value):
          out[e.key] = value;
        case PropString(:final value):
          out[e.key] = value;
        case PropList():
        case PropMap():
          // Nested types deferred (the engine's column store doesn't
          // carry these either).
          break;
      }
    }
    return out;
  }

  RemoteException _failureToException(BoltStruct failure) {
    final meta = failure.fields.isEmpty
        ? const <String, Object?>{}
        : failure.fields.first as Map<String, Object?>;
    final code = (meta['code'] as String?) ?? '';
    final msg = (meta['message'] as String?) ?? 'Neo4j failure';
    if (code.contains('Unauthorized') || code.contains('Forbidden')) {
      return AuthException(msg);
    }
    if (code.contains('ConstraintValidationFailed')) {
      return RemoteConstraintViolation(msg);
    }
    if (code.contains('TransactionTerminated')) {
      return TimeoutException(msg);
    }
    return ProtocolException('$code: $msg');
  }

  String _describe(BoltStruct s) {
    if (s.fields.isEmpty) return 'tag=0x${s.tag.toRadixString(16)}';
    return 'tag=0x${s.tag.toRadixString(16)} ${s.fields}';
  }
}

class _BoltTxn implements RemoteTxn {
  final BoltConnection _conn;
  final Neo4jClient _client;
  _BoltTxn(this._conn, this._client);

  @override
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  ) =>
      _client._runAndPull(_conn, query, params);
}
