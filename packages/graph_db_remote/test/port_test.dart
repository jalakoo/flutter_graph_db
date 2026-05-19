/// Port-shape tests for `RemoteGraphClient` (plan §9 / §14 Phase 4A).
///
/// These don't exercise any wire-level adapter — they pin the port's
/// contract via a hand-rolled `FakeRemoteClient` so future adapters
/// can be tested against a known shape.
library;

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:test/test.dart';

class _FakeTxn implements RemoteTxn {
  final List<(String, Map<String, Object?>)> calls = [];
  @override
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  ) async {
    calls.add((query, params));
    return RemoteQueryResult(
      columns: const ['n'],
      rows: [RemoteRow({'n': params['vid'] ?? 0})],
    );
  }
}

class FakeRemoteClient implements RemoteGraphClient {
  bool connected = false;
  bool closed = false;
  final List<String> queryLog = [];
  final List<ImportOp> imported = [];
  bool throwOnNextConnect = false;

  @override
  CapabilityFlags get capabilities => CapabilityFlags.fake;

  @override
  Future<void> connect() async {
    if (throwOnNextConnect) {
      throw const ConnectionException('simulated connect failure');
    }
    connected = true;
  }

  @override
  Future<void> close() async {
    closed = true;
    connected = false;
  }

  @override
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  ) async {
    if (!connected) {
      throw const ConnectionException('client is not connected');
    }
    queryLog.add(query);
    return RemoteQueryResult(
      columns: const ['echo'],
      rows: [RemoteRow({'echo': query})],
    );
  }

  @override
  Future<T> runInTransaction<T>(Future<T> Function(RemoteTxn) body) async {
    final txn = _FakeTxn();
    return body(txn);
  }

  @override
  Future<ImportResult> bulkImport(Stream<ImportOp> ops) async {
    var nodes = 0;
    var edges = 0;
    final sw = Stopwatch()..start();
    await for (final op in ops) {
      imported.add(op);
      if (op is ImportNode) nodes++;
      if (op is ImportEdge) edges++;
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
    yield const RemoteNode(
      logicalId: 'n-1',
      labels: ['Demo'],
      properties: {},
    );
    yield const RemoteEdge(
      logicalId: 'e-1',
      type: 'demo',
      srcLogicalId: 'n-1',
      dstLogicalId: 'n-1',
      properties: {},
    );
  }
}

void main() {
  group('RemoteGraphClient port', () {
    test('typical lifecycle: connect → query → close', () async {
      final c = FakeRemoteClient();
      await c.connect();
      expect(c.connected, isTrue);
      final r = await c.executeQuery('RETURN 1', const {});
      expect(r.columns, ['echo']);
      expect(c.queryLog, ['RETURN 1']);
      await c.close();
      expect(c.closed, isTrue);
    });

    test('query before connect raises ConnectionException', () async {
      final c = FakeRemoteClient();
      await expectLater(
        () => c.executeQuery('x', const {}),
        throwsA(isA<ConnectionException>()),
      );
    });

    test('runInTransaction passes a usable RemoteTxn', () async {
      final c = FakeRemoteClient();
      await c.connect();
      final r = await c.runInTransaction((txn) async {
        return await txn.executeQuery('MATCH (n) RETURN n', {'vid': 42});
      });
      expect(r.rows.single['n'], 42);
    });

    test('bulkImport drains the stream + counts ops', () async {
      final c = FakeRemoteClient();
      await c.connect();
      Stream<ImportOp> ops() async* {
        yield const ImportNode(
          logicalId: 'a', labels: ['L'], properties: {},
        );
        yield const ImportEdge(
          logicalId: 'e',
          srcLogicalId: 'a',
          dstLogicalId: 'a',
          type: 't',
          properties: {},
        );
      }
      final r = await c.bulkImport(ops());
      expect(r.nodesImported, 1);
      expect(r.edgesImported, 1);
    });

    test('bulkExport yields nodes + edges; consumer discriminates', () async {
      final c = FakeRemoteClient();
      await c.connect();
      final items = <Object>[];
      await for (final e in c.bulkExport(const SubgraphSpec())) {
        items.add(e);
      }
      expect(items.length, 2);
      expect(items[0], isA<RemoteNode>());
      expect(items[1], isA<RemoteEdge>());
    });
  });

  group('error hierarchy', () {
    test('every subclass is a RemoteException', () {
      const errors = <RemoteException>[
        ConnectionException('x'),
        AuthException('x'),
        TimeoutException('x'),
        RemoteConstraintViolation('x'),
        ProtocolException('x'),
        UnavailableException('x'),
        UnsupportedOperationException('x'),
      ];
      for (final e in errors) {
        expect(e, isA<RemoteException>());
        expect(e, isA<Exception>());
      }
    });

    test('toString includes the cause when present', () {
      const e = ConnectionException('lost', cause: 'socket reset');
      expect(e.toString(), contains('lost'));
      expect(e.toString(), contains('socket reset'));
    });
  });

  group('capability flags', () {
    test('fake reports every flag off', () {
      const c = CapabilityFlags.fake;
      expect(c.supportsTransactions, isFalse);
      expect(c.supportsConstraints, isFalse);
      expect(c.cypherDialect, CypherDialect.none);
      expect(c.serverVersion, 'fake');
    });
  });

  group('result + import/export types', () {
    test('RemoteNode + RemoteEdge implement the GraphNode / GraphEdge'
        ' interfaces', () {
      const node = RemoteNode(
        logicalId: 'n', labels: ['P'], properties: {},
      );
      const edge = RemoteEdge(
        logicalId: 'e',
        type: 't',
        srcLogicalId: 'n',
        dstLogicalId: 'n',
        properties: {},
      );
      expect(node, isA<GraphNode>());
      expect(edge, isA<GraphEdge>());
    });

    test('RemoteQueryResult exposes columns + rows + length', () {
      const r = RemoteQueryResult(
        columns: ['a', 'b'],
        rows: [RemoteRow({'a': 1, 'b': 2})],
      );
      expect(r.columns, ['a', 'b']);
      expect(r.length, 1);
      expect(r.rows.single['a'], 1);
    });

    test('PropValue boundary type re-exported (decoupled local/remote)',
        () {
      // `RemoteNode.properties` is typed `Map<String, PropValue>`
      // — adapters convert backend rows into PropValue at the
      // boundary, the same shape `graph_db_core` uses internally.
      final p = <String, PropValue>{
        'name': const PropString('Ada'),
        'age': const PropInt(36),
      };
      final n = RemoteNode(
          logicalId: 'n', labels: const ['P'], properties: p);
      expect(n.properties['name'], isA<PropString>());
      expect(n.properties['age'], isA<PropInt>());
    });
  });
}
