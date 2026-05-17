import 'dart:io';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/io_wal_store.dart';
import 'package:graph_db_wal/graph_db_wal.dart' show WalStore;
import 'package:test/test.dart';

Uint8List _bytes(List<int> xs) => Uint8List.fromList(xs);

Future<Uint8List> _readAll(WalStore store, {int fromOffset = 0}) async {
  final out = <int>[];
  await for (final chunk in store.read(fromOffset: fromOffset)) {
    out.addAll(chunk);
  }
  return Uint8List.fromList(out);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('graph_db_wal_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String walPath() => '${tempDir.path}${Platform.pathSeparator}wal.cbor';

  test('append + read round-trips byte-identical', () async {
    final store = await IoWalStore.open(walPath());
    try {
      await store.append(_bytes([1, 2, 3]), durability: Durability.group);
      await store.append(_bytes([4, 5, 6, 7]), durability: Durability.fsync);
      expect(store.length, 7);
      expect(await _readAll(store), _bytes([1, 2, 3, 4, 5, 6, 7]));
    } finally {
      await store.close();
    }
  });

  test('persistence — reopen sees previously appended bytes', () async {
    final path = walPath();
    final a = await IoWalStore.open(path);
    await a.append(_bytes([9, 8, 7]), durability: Durability.fsync);
    await a.close();

    final b = await IoWalStore.open(path);
    try {
      expect(b.length, 3);
      expect(await _readAll(b), _bytes([9, 8, 7]));
    } finally {
      await b.close();
    }
  });

  test('read from an offset works mid-stream', () async {
    final store = await IoWalStore.open(walPath());
    try {
      await store.append(_bytes([1, 2, 3, 4, 5]), durability: Durability.group);
      expect(await _readAll(store, fromOffset: 2), _bytes([3, 4, 5]));
    } finally {
      await store.close();
    }
  });

  test('truncate drops the prefix and shifts the tail to byte 0',
      () async {
    final store = await IoWalStore.open(walPath());
    try {
      await store.append(_bytes([1, 2, 3, 4, 5]), durability: Durability.fsync);
      final retained = await store.truncate(upToOffset: 2);
      expect(retained, 2);
      expect(store.length, 3);
      expect(await _readAll(store), _bytes([3, 4, 5]));
      // Appending after truncate continues at the new tip.
      await store.append(_bytes([6, 7]), durability: Durability.fsync);
      expect(store.length, 5);
      expect(await _readAll(store), _bytes([3, 4, 5, 6, 7]));
    } finally {
      await store.close();
    }
  });

  test('truncate survives a close+reopen cycle', () async {
    final path = walPath();
    final a = await IoWalStore.open(path);
    await a.append(_bytes([1, 2, 3, 4, 5]), durability: Durability.fsync);
    await a.truncate(upToOffset: 2);
    await a.close();

    final b = await IoWalStore.open(path);
    try {
      expect(b.length, 3);
      expect(await _readAll(b), _bytes([3, 4, 5]));
    } finally {
      await b.close();
    }
  });

  test('truncate past the end zeroes the file', () async {
    final store = await IoWalStore.open(walPath());
    try {
      await store.append(_bytes([1, 2, 3]), durability: Durability.fsync);
      final retained = await store.truncate(upToOffset: 10);
      expect(retained, 10);
      expect(store.length, 0);
      expect(await _readAll(store), Uint8List(0));
    } finally {
      await store.close();
    }
  });

  test('close prevents further appends + reads', () async {
    final store = await IoWalStore.open(walPath());
    await store.append(_bytes([1]), durability: Durability.group);
    await store.close();
    expect(
      () => store.append(_bytes([2]), durability: Durability.group),
      throwsA(isA<StateError>()),
    );
  });
}
