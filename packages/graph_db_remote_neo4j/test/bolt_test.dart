@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_remote_neo4j/graph_db_remote_neo4j.dart';
import 'package:test/test.dart';

/// In-process mock transport. The test writes "server" responses
/// onto [serverOut]; the BoltConnection reads them via [input].
class MockTransport implements BoltTransport {
  final StreamController<Uint8List> _serverOut =
      StreamController<Uint8List>();
  final BytesBuilder writes = BytesBuilder(copy: false);
  bool closed = false;

  @override
  Stream<Uint8List> get input => _serverOut.stream;

  void serverSend(Uint8List bytes) => _serverOut.add(bytes);

  @override
  Future<void> write(Uint8List bytes) async {
    writes.add(bytes);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _serverOut.close();
  }
}

void main() {
  group('PackStream round-trips', () {
    Object? roundTrip(Object? v) {
      final enc = PackStreamEncoder()..writeValue(v);
      return PackStreamDecoder(enc.takeBytes()).readValue();
    }

    test('null / bool / int / double', () {
      expect(roundTrip(null), isNull);
      expect(roundTrip(true), true);
      expect(roundTrip(false), false);
      expect(roundTrip(0), 0);
      expect(roundTrip(42), 42);
      expect(roundTrip(-1), -1);
      expect(roundTrip(200), 200);
      expect(roundTrip(-200), -200);
      expect(roundTrip(70000), 70000);
      expect(roundTrip(-70000), -70000);
      expect(roundTrip(5000000000), 5000000000);
      expect(roundTrip(3.14), 3.14);
    });

    test('strings — tiny + full', () {
      expect(roundTrip(''), '');
      expect(roundTrip('hello'), 'hello');
      expect(roundTrip('a' * 20), 'a' * 20);
      expect(roundTrip('a' * 300), 'a' * 300);
    });

    test('lists nested', () {
      expect(roundTrip([1, 2, 3]), [1, 2, 3]);
      expect(roundTrip([
        'a',
        [1, 2],
        null,
        true,
      ]), [
        'a',
        [1, 2],
        null,
        true,
      ]);
    });

    test('maps', () {
      final m = {'x': 1, 'y': 'two', 'z': true};
      expect(roundTrip(m), m);
    });

    test('struct', () {
      final s = BoltStruct(0x70, ['ok', 42]);
      final r = roundTrip(s) as BoltStruct;
      expect(r.tag, 0x70);
      expect(r.fields, ['ok', 42]);
    });
  });

  group('handshake', () {
    test('encodes magic + 4 versions', () {
      final bytes = buildHandshake(const [(major: 5, minor: 4)]);
      // 4 bytes magic + 16 bytes (4 versions × 4 bytes)
      expect(bytes.length, 20);
      expect(bytes.sublist(0, 4), [0x60, 0x60, 0xB0, 0x17]);
      // First version slot — [0, 0, minor=4, major=5]
      expect(bytes.sublist(4, 8), [0, 0, 4, 5]);
      // Remaining slots zero-padded.
      expect(bytes.sublist(8, 12), [0, 0, 0, 0]);
    });

    test('parses server selection', () {
      expect(
        parseHandshakeResponse(Uint8List.fromList([0, 0, 4, 5])),
        (major: 5, minor: 4),
      );
      expect(
        parseHandshakeResponse(Uint8List.fromList([0, 0, 0, 0])),
        isNull,
      );
    });
  });

  group('BoltConnection over mock transport', () {
    test('full handshake then HELLO → SUCCESS', () async {
      final mock = MockTransport();
      final conn = BoltConnection(mock);
      // Server responds: 4 bytes negotiating Bolt 5.4 + a SUCCESS
      // message for the HELLO.
      final successPayload = PackStreamEncoder()
        ..writeValue(BoltStruct(BoltMessage.success, [
          {'server': 'Neo4j/5.21.0', 'connection_id': 'test'},
        ]));
      // Pre-queue handshake response.
      mock.serverSend(Uint8List.fromList([0, 0, 4, 5]));
      // Pre-queue the chunked SUCCESS reply.
      mock.serverSend(frameMessage(successPayload.takeBytes()));

      final version = await conn.handshake();
      expect(version, (major: 5, minor: 4));

      await conn.send(buildHello(
        userAgent: 'test',
        scheme: 'none',
        principal: '',
        credentials: '',
      ));
      final reply = await conn.receive();
      expect(reply.tag, BoltMessage.success);
      final meta = reply.fields.first as Map;
      expect(meta['server'], 'Neo4j/5.21.0');
    });

    test('failure tag is delivered as-is for adapter mapping', () async {
      final mock = MockTransport();
      final conn = BoltConnection(mock);
      mock.serverSend(Uint8List.fromList([0, 0, 4, 5]));
      mock.serverSend(frameMessage(
        (PackStreamEncoder()
              ..writeValue(BoltStruct(BoltMessage.failure, [
                {
                  'code': 'Neo.ClientError.Security.Unauthorized',
                  'message': 'bad password',
                }
              ])))
            .takeBytes(),
      ));
      await conn.handshake();
      await conn.send(buildHello(
        userAgent: 't',
        scheme: 'basic',
        principal: 'x',
        credentials: 'wrong',
      ));
      final r = await conn.receive();
      expect(r.tag, BoltMessage.failure);
    });
  });

  group('Neo4jClient via mock transport (4C)', () {
    Future<MockTransport> makeMock({
      required Iterable<BoltStruct> serverReplies,
    }) async {
      final m = MockTransport();
      // version select
      m.serverSend(Uint8List.fromList([0, 0, 4, 5]));
      for (final r in serverReplies) {
        m.serverSend(frameMessage(
          (PackStreamEncoder()..writeValue(r)).takeBytes(),
        ));
      }
      return m;
    }

    test('connect succeeds and populates capabilities', () async {
      final mock = await makeMock(serverReplies: [
        BoltStruct(BoltMessage.success, [
          {'server': 'Neo4j/5.21.0'}
        ]),
      ]);
      final client = Neo4jClient.withTransport(
        const Neo4jClientConfig(host: 'mock', username: 'u', password: 'p'),
        () async => mock,
      );
      await client.connect();
      expect(client.capabilities.cypherDialect, CypherDialect.neo4j);
      expect(client.capabilities.serverVersion, contains('Neo4j/5.21.0'));
      await client.close();
    });

    test('executeQuery walks RUN → SUCCESS → PULL → RECORDs → SUCCESS',
        () async {
      final mock = await makeMock(serverReplies: [
        // HELLO ack
        BoltStruct(BoltMessage.success, [
          {'server': 'Neo4j/5.21.0'}
        ]),
        // RUN ack — declares column names
        BoltStruct(BoltMessage.success, [
          {
            'fields': ['n.name', 'n.age']
          }
        ]),
        // RECORDs
        BoltStruct(BoltMessage.record, [
          ['Ada', 36]
        ]),
        BoltStruct(BoltMessage.record, [
          ['Bob', 25]
        ]),
        // PULL ack
        BoltStruct(BoltMessage.success, [
          {'type': 'r'}
        ]),
      ]);
      final client = Neo4jClient.withTransport(
        const Neo4jClientConfig(host: 'mock'),
        () async => mock,
      );
      await client.connect();
      final r = await client.executeQuery(
        'MATCH (n:Person) RETURN n.name, n.age',
        const {},
      );
      expect(r.columns, ['n.name', 'n.age']);
      expect(r.rows.length, 2);
      expect(r.rows[0]['n.name'], 'Ada');
      expect(r.rows[1]['n.age'], 25);
      await client.close();
    });

    test('FAILURE during RUN raises a typed RemoteException', () async {
      final mock = await makeMock(serverReplies: [
        BoltStruct(BoltMessage.success, [
          {'server': 'Neo4j/5.21.0'}
        ]),
        BoltStruct(BoltMessage.failure, [
          {
            'code': 'Neo.ClientError.Schema.ConstraintValidationFailed',
            'message': 'dup key',
          }
        ]),
        // RESET ack
        BoltStruct(BoltMessage.success, [const <String, Object?>{}]),
      ]);
      final client = Neo4jClient.withTransport(
        const Neo4jClientConfig(host: 'mock'),
        () async => mock,
      );
      await client.connect();
      await expectLater(
        () => client.executeQuery('CREATE (n {x:1})', const {}),
        throwsA(isA<RemoteConstraintViolation>()),
      );
      await client.close();
    });
  });
}
