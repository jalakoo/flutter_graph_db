/// Minimal PackStream encoder + decoder (Neo4j Bolt v4.x).
///
/// PackStream is a length-prefixed binary serialisation format. This
/// implementation covers the types needed for v1 Bolt traffic: Null /
/// Bool / Int / Float / String / List / Dictionary / Structure.
/// Node/Relationship/Path PackStream structs (tags `N`, `R`, `P`)
/// are decoded into [BoltNode] / [BoltRel] / [BoltPath] records the
/// adapter converts to engine-side `RemoteNode` / `RemoteEdge` /
/// `RemotePath`.
library;

import 'dart:convert';
import 'dart:typed_data';

class PackStreamException implements Exception {
  final String message;
  PackStreamException(this.message);
  @override
  String toString() => 'PackStreamException: $message';
}

/// One element of a Bolt struct. The tag is a single byte; fields are
/// arbitrary PackStream values. Adapters interpret the tag (e.g.
/// `0x70` = SUCCESS message, `0x4E` = Node struct).
class BoltStruct {
  final int tag;
  final List<Object?> fields;
  const BoltStruct(this.tag, this.fields);

  @override
  String toString() => 'BoltStruct(0x${tag.toRadixString(16)}, $fields)';
}

class PackStreamEncoder {
  final BytesBuilder _b = BytesBuilder(copy: false);

  Uint8List takeBytes() => _b.takeBytes();

  void writeValue(Object? v) {
    if (v == null) {
      _b.addByte(0xC0);
      return;
    }
    if (v is bool) {
      _b.addByte(v ? 0xC3 : 0xC2);
      return;
    }
    if (v is int) {
      _writeInt(v);
      return;
    }
    if (v is double) {
      _b.addByte(0xC1);
      final bd = ByteData(8)..setFloat64(0, v);
      _b.add(bd.buffer.asUint8List());
      return;
    }
    if (v is String) {
      _writeString(v);
      return;
    }
    if (v is List) {
      _writeList(v);
      return;
    }
    if (v is Map) {
      _writeMap(v);
      return;
    }
    if (v is BoltStruct) {
      _writeStruct(v);
      return;
    }
    throw PackStreamException('cannot encode ${v.runtimeType}');
  }

  void _writeInt(int v) {
    if (v >= -16 && v <= 127) {
      // TINY_INT is a single signed byte for -16..127.
      _b.addByte(v & 0xFF);
    } else if (v >= -128 && v <= 127) {
      _b.addByte(0xC8);
      _b.addByte(v & 0xFF);
    } else if (v >= -32768 && v <= 32767) {
      _b.addByte(0xC9);
      final bd = ByteData(2)..setInt16(0, v);
      _b.add(bd.buffer.asUint8List());
    } else if (v >= -2147483648 && v <= 2147483647) {
      _b.addByte(0xCA);
      final bd = ByteData(4)..setInt32(0, v);
      _b.add(bd.buffer.asUint8List());
    } else {
      _b.addByte(0xCB);
      final bd = ByteData(8)..setInt64(0, v);
      _b.add(bd.buffer.asUint8List());
    }
  }

  void _writeString(String s) {
    final bytes = utf8.encode(s);
    final n = bytes.length;
    if (n < 16) {
      _b.addByte(0x80 | n);
    } else if (n < 256) {
      _b.addByte(0xD0);
      _b.addByte(n);
    } else if (n < 65536) {
      _b.addByte(0xD1);
      final bd = ByteData(2)..setUint16(0, n);
      _b.add(bd.buffer.asUint8List());
    } else {
      _b.addByte(0xD2);
      final bd = ByteData(4)..setUint32(0, n);
      _b.add(bd.buffer.asUint8List());
    }
    _b.add(bytes);
  }

  void _writeList(List<Object?> list) {
    final n = list.length;
    if (n < 16) {
      _b.addByte(0x90 | n);
    } else if (n < 256) {
      _b.addByte(0xD4);
      _b.addByte(n);
    } else if (n < 65536) {
      _b.addByte(0xD5);
      final bd = ByteData(2)..setUint16(0, n);
      _b.add(bd.buffer.asUint8List());
    } else {
      _b.addByte(0xD6);
      final bd = ByteData(4)..setUint32(0, n);
      _b.add(bd.buffer.asUint8List());
    }
    for (final e in list) {
      writeValue(e);
    }
  }

  void _writeMap(Map<dynamic, dynamic> map) {
    final n = map.length;
    if (n < 16) {
      _b.addByte(0xA0 | n);
    } else if (n < 256) {
      _b.addByte(0xD8);
      _b.addByte(n);
    } else if (n < 65536) {
      _b.addByte(0xD9);
      final bd = ByteData(2)..setUint16(0, n);
      _b.add(bd.buffer.asUint8List());
    } else {
      _b.addByte(0xDA);
      final bd = ByteData(4)..setUint32(0, n);
      _b.add(bd.buffer.asUint8List());
    }
    for (final e in map.entries) {
      writeValue(e.key.toString());
      writeValue(e.value);
    }
  }

  void _writeStruct(BoltStruct s) {
    final n = s.fields.length;
    if (n < 16) {
      _b.addByte(0xB0 | n);
    } else if (n < 256) {
      _b.addByte(0xDC);
      _b.addByte(n);
    } else {
      _b.addByte(0xDD);
      final bd = ByteData(2)..setUint16(0, n);
      _b.add(bd.buffer.asUint8List());
    }
    _b.addByte(s.tag);
    for (final f in s.fields) {
      writeValue(f);
    }
  }
}

class PackStreamDecoder {
  final Uint8List _bytes;
  int _pos = 0;
  PackStreamDecoder(this._bytes);

  bool get atEnd => _pos >= _bytes.length;

  int get position => _pos;

  Object? readValue() {
    if (_pos >= _bytes.length) {
      throw PackStreamException('unexpected end of input');
    }
    final marker = _bytes[_pos++];
    // TINY_STRING / TINY_LIST / TINY_MAP / TINY_STRUCT — high nibble
    final hi = marker & 0xF0;
    final lo = marker & 0x0F;
    if (hi == 0x80) return _readString(lo);
    if (hi == 0x90) return _readList(lo);
    if (hi == 0xA0) return _readMap(lo);
    if (hi == 0xB0) return _readStruct(lo);
    // TINY_INT — top bit zero (positive 0..127) or top nibble F (negative -16..-1)
    if (marker <= 0x7F) return marker;
    if (marker >= 0xF0) return marker - 256;
    switch (marker) {
      case 0xC0:
        return null;
      case 0xC1:
        final v = ByteData.sublistView(_bytes, _pos, _pos + 8).getFloat64(0);
        _pos += 8;
        return v;
      case 0xC2:
        return false;
      case 0xC3:
        return true;
      case 0xC8:
        return ByteData.sublistView(_bytes, _pos, ++_pos).getInt8(0);
      case 0xC9:
        final v = ByteData.sublistView(_bytes, _pos, _pos + 2).getInt16(0);
        _pos += 2;
        return v;
      case 0xCA:
        final v = ByteData.sublistView(_bytes, _pos, _pos + 4).getInt32(0);
        _pos += 4;
        return v;
      case 0xCB:
        final v = ByteData.sublistView(_bytes, _pos, _pos + 8).getInt64(0);
        _pos += 8;
        return v;
      case 0xD0:
        return _readString(_bytes[_pos++]);
      case 0xD1:
        final n = ByteData.sublistView(_bytes, _pos, _pos + 2).getUint16(0);
        _pos += 2;
        return _readString(n);
      case 0xD2:
        final n = ByteData.sublistView(_bytes, _pos, _pos + 4).getUint32(0);
        _pos += 4;
        return _readString(n);
      case 0xD4:
        return _readList(_bytes[_pos++]);
      case 0xD5:
        final n = ByteData.sublistView(_bytes, _pos, _pos + 2).getUint16(0);
        _pos += 2;
        return _readList(n);
      case 0xD6:
        final n = ByteData.sublistView(_bytes, _pos, _pos + 4).getUint32(0);
        _pos += 4;
        return _readList(n);
      case 0xD8:
        return _readMap(_bytes[_pos++]);
      case 0xD9:
        final n = ByteData.sublistView(_bytes, _pos, _pos + 2).getUint16(0);
        _pos += 2;
        return _readMap(n);
      case 0xDA:
        final n = ByteData.sublistView(_bytes, _pos, _pos + 4).getUint32(0);
        _pos += 4;
        return _readMap(n);
      case 0xDC:
        return _readStruct(_bytes[_pos++]);
      case 0xDD:
        final n = ByteData.sublistView(_bytes, _pos, _pos + 2).getUint16(0);
        _pos += 2;
        return _readStruct(n);
      default:
        throw PackStreamException(
            'unsupported marker 0x${marker.toRadixString(16)}');
    }
  }

  String _readString(int n) {
    final s = utf8.decode(_bytes.sublist(_pos, _pos + n));
    _pos += n;
    return s;
  }

  List<Object?> _readList(int n) {
    final out = <Object?>[];
    for (var i = 0; i < n; i++) {
      out.add(readValue());
    }
    return out;
  }

  Map<String, Object?> _readMap(int n) {
    final out = <String, Object?>{};
    for (var i = 0; i < n; i++) {
      final k = readValue();
      final v = readValue();
      out[k.toString()] = v;
    }
    return out;
  }

  BoltStruct _readStruct(int n) {
    final tag = _bytes[_pos++];
    final fields = <Object?>[];
    for (var i = 0; i < n; i++) {
      fields.add(readValue());
    }
    return BoltStruct(tag, fields);
  }
}
