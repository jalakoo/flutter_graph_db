/// Minimal RESP2 codec + framed decoder (FalkorDB rides RESP).
///
/// RESP2 prefixes every value with a single byte:
///   `+` simple string,  `-` error,  `:` integer,
///   `$` bulk string ($-1 = nil),  `*` array (*-1 = nil array).
/// Lines end in CRLF. Bulk-string + array shapes carry an inline
/// length count and their elements recurse.
library;

import 'dart:convert';
import 'dart:typed_data';

class RespException implements Exception {
  final String message;
  RespException(this.message);
  @override
  String toString() => 'RespException: $message';
}

/// Wire-side error (the `-` reply). Adapters lift this into a typed
/// [`RemoteException`] subclass at the boundary.
class RespError implements Exception {
  final String message;
  RespError(this.message);
  @override
  String toString() => 'RespError: $message';
}

/// Encodes a command as an array-of-bulk-strings, the RESP convention
/// for client → server requests. `SET key value` becomes
/// `*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n`.
Uint8List encodeCommand(List<String> args) {
  final b = BytesBuilder(copy: false);
  b.add(utf8.encode('*${args.length}\r\n'));
  for (final a in args) {
    final bytes = utf8.encode(a);
    b.add(utf8.encode('\$${bytes.length}\r\n'));
    b.add(bytes);
    b.add(_crlf);
  }
  return b.takeBytes();
}

final Uint8List _crlf = Uint8List.fromList([0x0D, 0x0A]);

/// Stateful RESP decoder — feed bytes off the wire, drain completed
/// values via [pull].
class RespDecoder {
  final List<int> _buf = [];
  final List<Object?> _completed = [];

  void feed(List<int> bytes) {
    _buf.addAll(bytes);
    while (true) {
      final start = _completed.length;
      final consumed = _tryParse(0);
      if (consumed == null) return;
      _buf.removeRange(0, consumed);
      // _tryParse pushed exactly one value to _completed on success.
      assert(_completed.length == start + 1);
    }
  }

  /// Returns and clears every completed top-level value.
  Iterable<Object?> pull() sync* {
    while (_completed.isNotEmpty) {
      yield _completed.removeAt(0);
    }
  }

  /// Returns the number of bytes consumed, or `null` if more data is
  /// needed. On success, appends exactly one value to [_completed].
  int? _tryParse(int from) {
    if (from >= _buf.length) return null;
    final prefix = _buf[from];
    final lineEnd = _findLineEnd(from + 1);
    if (lineEnd < 0) return null;
    final line = String.fromCharCodes(_buf.sublist(from + 1, lineEnd));
    final afterLine = lineEnd + 2; // skip \r\n
    switch (prefix) {
      case 0x2B: // '+'
        _completed.add(line);
        return afterLine - from;
      case 0x2D: // '-'
        _completed.add(RespError(line));
        return afterLine - from;
      case 0x3A: // ':'
        _completed.add(int.parse(line));
        return afterLine - from;
      case 0x24: // '$'
        final n = int.parse(line);
        if (n < 0) {
          _completed.add(null);
          return afterLine - from;
        }
        if (_buf.length < afterLine + n + 2) return null;
        final bytes = _buf.sublist(afterLine, afterLine + n);
        _completed.add(utf8.decode(bytes));
        return afterLine + n + 2 - from;
      case 0x2A: // '*'
        final n = int.parse(line);
        if (n < 0) {
          _completed.add(null);
          return afterLine - from;
        }
        // Recursive parse — peek N nested values. We need to track
        // them but _tryParse pushes to _completed. Approach: pop the
        // last N items after they're parsed and bundle into a list.
        var cursor = afterLine;
        final marker = _completed.length;
        for (var i = 0; i < n; i++) {
          final consumed = _tryParse(cursor);
          if (consumed == null) {
            // Rollback any partial pushes for this array.
            while (_completed.length > marker) {
              _completed.removeLast();
            }
            return null;
          }
          cursor += consumed;
        }
        // Collect the trailing N elements into a list.
        final list = List<Object?>.from(
          _completed.sublist(marker, marker + n),
        );
        _completed.removeRange(marker, marker + n);
        _completed.add(list);
        return cursor - from;
      default:
        throw RespException(
          'unknown RESP prefix 0x${prefix.toRadixString(16)}',
        );
    }
  }

  int _findLineEnd(int from) {
    for (var i = from; i + 1 < _buf.length; i++) {
      if (_buf[i] == 0x0D && _buf[i + 1] == 0x0A) return i;
    }
    return -1;
  }
}
