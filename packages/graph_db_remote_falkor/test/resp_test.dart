@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_remote_falkor/graph_db_remote_falkor.dart';
import 'package:test/test.dart';

class MockRespTransport implements RespTransport {
  final StreamController<Uint8List> _ctl =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> writes = [];
  bool closed = false;
  @override
  Stream<Uint8List> get input => _ctl.stream;
  void serverSend(String text) => _ctl.add(Uint8List.fromList(text.codeUnits));
  void serverSendBytes(Uint8List bytes) => _ctl.add(bytes);
  @override
  Future<void> write(Uint8List bytes) async {
    writes.add(bytes);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _ctl.close();
  }
}

void main() {
  group('RESP encode + decode round-trips', () {
    test('encodeCommand emits the array-of-bulk-strings shape', () {
      final bytes = encodeCommand(['SET', 'k', 'v']);
      expect(String.fromCharCodes(bytes),
          '*3\r\n\$3\r\nSET\r\n\$1\r\nk\r\n\$1\r\nv\r\n');
    });

    Object? decode(String wire) {
      final d = RespDecoder();
      d.feed(wire.codeUnits);
      return d.pull().single;
    }

    test('decodes every type', () {
      expect(decode('+OK\r\n'), 'OK');
      expect(decode(':42\r\n'), 42);
      expect(decode('\$5\r\nhello\r\n'), 'hello');
      expect(decode('\$-1\r\n'), isNull);
      expect(
          decode('*3\r\n:1\r\n:2\r\n:3\r\n'), [1, 2, 3]);
      final err = decode('-ERR bad\r\n');
      expect(err, isA<RespError>());
      expect((err as RespError).message, 'ERR bad');
    });

    test('nested arrays', () {
      final r =
          decode('*2\r\n*2\r\n:1\r\n:2\r\n*2\r\n:3\r\n:4\r\n');
      expect(r, [
        [1, 2],
        [3, 4],
      ]);
    });

    test('decoder handles split chunks', () {
      final d = RespDecoder();
      d.feed('\$5\r\nhel'.codeUnits);
      expect(d.pull(), isEmpty);
      d.feed('lo\r\n'.codeUnits);
      expect(d.pull().single, 'hello');
    });
  });

  group('FalkorClient via mock transport (4E)', () {
    test('connect sends AUTH + PING + INFO and populates capabilities',
        () async {
      final mock = MockRespTransport();
      // Queue responses: AUTH ok, PING pong, INFO with version line.
      Future<void> respond(String text) async {
        await Future<void>.delayed(Duration.zero);
        mock.serverSend(text);
      }

      final client = FalkorClient.withTransport(
        const FalkorClientConfig(
          host: 'mock',
          graph: 'g',
          username: 'u',
          password: 'p',
        ),
        () async => mock,
      );
      // We need to interleave server responses with the client's
      // outgoing requests — fire them in order via microtasks.
      final connectFuture = client.connect();
      // AUTH reply
      await respond('+OK\r\n');
      // PING reply
      await respond('+PONG\r\n');
      // INFO server reply (one bulk string)
      const info = 'redis_version:7.2.0\r\nredis_mode:standalone\r\n';
      await respond('\$${info.length}\r\n$info\r\n');
      await connectFuture;
      expect(client.capabilities.cypherDialect, CypherDialect.falkor);
      expect(
          client.capabilities.serverVersion, contains('Redis 7.2.0'));
      await client.close();
    });

    test('executeQuery returns columns + rows from GRAPH.QUERY reply',
        () async {
      final mock = MockRespTransport();
      Future<void> respond(String text) async {
        await Future<void>.delayed(Duration.zero);
        mock.serverSend(text);
      }

      final client = FalkorClient.withTransport(
        const FalkorClientConfig(host: 'mock', graph: 'g'),
        () async => mock,
      );
      final connectFuture = client.connect();
      await respond('+PONG\r\n');
      await respond('\$0\r\n\r\n');
      await connectFuture;
      // GRAPH.QUERY reply: [ headers, records, stats ]
      //   headers = [ [type, "n.name"] ]
      //   records = [ ["Ada"], ["Bob"] ]
      //   stats   = (a single bulk string is fine — we don't read it)
      final qFuture = client.executeQuery(
        'MATCH (n) RETURN n.name',
        const {},
      );
      const reply = '*3\r\n'
          '*1\r\n*2\r\n:1\r\n\$6\r\nn.name\r\n'
          '*2\r\n*1\r\n\$3\r\nAda\r\n*1\r\n\$3\r\nBob\r\n'
          '\$0\r\n\r\n';
      await respond(reply);
      final r = await qFuture;
      expect(r.columns, ['n.name']);
      expect(r.rows.map((x) => x['n.name']).toList(), ['Ada', 'Bob']);
      await client.close();
    });

    test('RESP error → RemoteConstraintViolation on parallel-edge text',
        () async {
      final mock = MockRespTransport();
      Future<void> respond(String text) async {
        await Future<void>.delayed(Duration.zero);
        mock.serverSend(text);
      }

      final client = FalkorClient.withTransport(
        const FalkorClientConfig(host: 'mock', graph: 'g'),
        () async => mock,
      );
      final connect = client.connect();
      await respond('+PONG\r\n');
      await respond('\$0\r\n\r\n');
      await connect;
      final q = client.executeQuery(
        'CREATE (a)-[:T]->(b)',
        const {},
      );
      await respond('-FalkorDB: parallel edges not supported\r\n');
      await expectLater(q, throwsA(isA<RemoteConstraintViolation>()));
      await client.close();
    });
  });
}
