/// Bolt v4.x message tags + builders.
library;

import 'packstream.dart';

/// Client → server message tags.
class BoltMessage {
  static const int hello = 0x01;
  static const int goodbye = 0x02;
  static const int reset = 0x0F;
  static const int run = 0x10;
  static const int discard = 0x2F;
  static const int pull = 0x3F;
  // Bolt 4.4 begin/commit/rollback
  static const int begin = 0x11;
  static const int commit = 0x12;
  static const int rollback = 0x13;

  /// Server → client.
  static const int success = 0x70;
  static const int record = 0x71;
  static const int ignored = 0x7E;
  static const int failure = 0x7F;
}

/// Encodes a HELLO message: `HELLO {auth_metadata}` where the
/// metadata map carries `user_agent`, `scheme`, `principal`,
/// `credentials`. Minimal builder — adapters call this.
BoltStruct buildHello({
  required String userAgent,
  required String scheme,
  required String principal,
  required String credentials,
}) =>
    BoltStruct(BoltMessage.hello, [
      <String, Object?>{
        'user_agent': userAgent,
        'scheme': scheme,
        'principal': principal,
        'credentials': credentials,
      }
    ]);

/// `RUN cypher {params} {metadata}` — metadata can carry mode (`r` /
/// `w`), bookmarks, etc. v1 sends empty metadata.
BoltStruct buildRun(String query, Map<String, Object?> params) => BoltStruct(
      BoltMessage.run,
      [query, params, const <String, Object?>{}],
    );

/// `PULL {n}` — request up to `n` records (or -1 for all). Bolt
/// metadata also carries `qid` for multiplexed statements; v1 keeps
/// it default (one statement at a time).
BoltStruct buildPull({int n = -1}) =>
    BoltStruct(BoltMessage.pull, [
      <String, Object?>{'n': n}
    ]);

BoltStruct buildBegin() =>
    BoltStruct(BoltMessage.begin, const [<String, Object?>{}]);
BoltStruct buildCommit() => BoltStruct(BoltMessage.commit, const []);
BoltStruct buildRollback() => BoltStruct(BoltMessage.rollback, const []);
BoltStruct buildGoodbye() => BoltStruct(BoltMessage.goodbye, const []);
BoltStruct buildReset() => BoltStruct(BoltMessage.reset, const []);

/// Bolt-side node struct: tag `0x4E` ('N'), fields = [id, labels,
/// properties, elementId?] (elementId added in Bolt 5+, optional).
const int boltNodeTag = 0x4E;
const int boltRelTag = 0x52;
const int boltPathTag = 0x50;
