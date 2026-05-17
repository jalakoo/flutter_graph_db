/// Bolt connection handshake.
///
/// 1. Client sends a 4-byte magic preamble `0x60 60 B0 17`.
/// 2. Client sends 4 supported versions, each a 4-byte big-endian int
///    encoded as `[0, 0, minor, major]` for v4.x and beyond.
/// 3. Server replies with a 4-byte int — the selected version, or
///    `0 0 0 0` if no version matched.
library;

import 'dart:typed_data';

/// Magic preamble.
final Uint8List kBoltMagic = Uint8List.fromList(const [0x60, 0x60, 0xB0, 0x17]);

/// Encodes a Bolt version as 4 bytes — `[0, 0, minor, major]`.
Uint8List encodeVersion({required int major, required int minor}) =>
    Uint8List.fromList([0, 0, minor, major]);

/// Builds the full client-side handshake payload: magic + 4 versions.
/// Order matters — server picks the first match.
Uint8List buildHandshake(List<({int major, int minor})> versions) {
  if (versions.length > 4) {
    throw ArgumentError('handshake offers up to 4 versions, got ${versions.length}');
  }
  final out = BytesBuilder(copy: false)..add(kBoltMagic);
  for (var i = 0; i < 4; i++) {
    if (i < versions.length) {
      out.add(encodeVersion(
        major: versions[i].major,
        minor: versions[i].minor,
      ));
    } else {
      out.add(Uint8List(4)); // zero padding for unused slots
    }
  }
  return out.takeBytes();
}

/// Parses the server's 4-byte response. Returns `(major, minor)`, or
/// `null` if the server rejected (`00 00 00 00`).
({int major, int minor})? parseHandshakeResponse(Uint8List bytes) {
  if (bytes.length < 4) {
    throw ArgumentError('handshake response must be ≥ 4 bytes');
  }
  if (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0) {
    return null;
  }
  return (major: bytes[3], minor: bytes[2]);
}

/// Default version list — Bolt 5.4, 5.0, 4.4, 4.0 (covers Neo4j 4.x +
/// 5.x). Server picks the highest match.
const List<({int major, int minor})> kDefaultVersions = [
  (major: 5, minor: 4),
  (major: 5, minor: 0),
  (major: 4, minor: 4),
  (major: 4, minor: 0),
];
