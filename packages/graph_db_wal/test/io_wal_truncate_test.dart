@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:graph_db_wal/io_wal_store.dart';
import 'package:test/test.dart';

/// `IoWalStore.truncate` must be atomic and bounded in memory.
///
/// Regression: it used to reopen the WAL with `FileMode.write` — which
/// truncates to zero — and then write the retained tail back in place. A
/// crash inside that window lost the whole tail, i.e. every commit acked
/// after the snapshot was captured.

late Directory _tmp;

String _path(String name) => '${_tmp.path}/$name';

Future<Uint8List> _readAll(IoWalStore store, {int fromOffset = 0}) async {
  final out = <int>[];
  await for (final chunk in store.read(fromOffset: fromOffset)) {
    out.addAll(chunk);
  }
  return Uint8List.fromList(out);
}

Uint8List _pattern(int start, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (start + i) % 251]);

void main() {
  setUp(() async {
    _tmp = await Directory.systemTemp.createTemp('wal_truncate_test');
  });
  tearDown(() async {
    if (_tmp.existsSync()) await _tmp.delete(recursive: true);
  });

  test('retains the tail exactly', () async {
    final store = await IoWalStore.open(_path('a.wal'));
    await store.append(_pattern(0, 100), durability: Durability.fsync);
    await store.append(_pattern(100, 100), durability: Durability.fsync);
    expect(store.length, 200);

    final retained = await store.truncate(upToOffset: 100);

    expect(retained, 100);
    expect(store.length, 100);
    expect(await _readAll(store), _pattern(100, 100));
    await store.close();
  });

  test('appends land correctly after a truncate', () async {
    final store = await IoWalStore.open(_path('b.wal'));
    await store.append(_pattern(0, 64), durability: Durability.fsync);
    await store.append(_pattern(64, 64), durability: Durability.fsync);
    await store.truncate(upToOffset: 64);
    await store.append(_pattern(200, 32), durability: Durability.fsync);

    expect(store.length, 96);
    expect(await _readAll(store),
        Uint8List.fromList([..._pattern(64, 64), ..._pattern(200, 32)]));
    await store.close();
  });

  test('survives a tail larger than one copy chunk', () async {
    final store = await IoWalStore.open(_path('c.wal'));
    // 64 KiB chunk size — use a tail spanning several chunks plus a
    // partial one so the streaming loop's arithmetic is exercised.
    const dropped = 1000;
    const tailLength = 64 * 1024 * 2 + 777;
    await store.append(_pattern(0, dropped), durability: Durability.fsync);
    await store.append(_pattern(7, tailLength), durability: Durability.fsync);

    await store.truncate(upToOffset: dropped);

    expect(store.length, tailLength);
    expect(await _readAll(store), _pattern(7, tailLength));
    await store.close();
  });

  test('truncating the whole file empties it', () async {
    final store = await IoWalStore.open(_path('d.wal'));
    await store.append(_pattern(0, 50), durability: Durability.fsync);
    final retained = await store.truncate(upToOffset: 50);
    expect(retained, 50);
    expect(store.length, 0);
    expect(await _readAll(store), isEmpty);
    // Still writable.
    await store.append(_pattern(9, 10), durability: Durability.fsync);
    expect(store.length, 10);
    expect(await _readAll(store), _pattern(9, 10));
    await store.close();
  });

  test('upToOffset beyond the length empties it', () async {
    final store = await IoWalStore.open(_path('e.wal'));
    await store.append(_pattern(0, 20), durability: Durability.fsync);
    await store.truncate(upToOffset: 9999);
    expect(store.length, 0);
    await store.close();
  });

  test('upToOffset <= 0 is a no-op', () async {
    final store = await IoWalStore.open(_path('f.wal'));
    await store.append(_pattern(0, 20), durability: Durability.fsync);
    expect(await store.truncate(upToOffset: 0), 0);
    expect(store.length, 20);
    expect(await _readAll(store), _pattern(0, 20));
    await store.close();
  });

  test('leaves no temp file behind', () async {
    final store = await IoWalStore.open(_path('g.wal'));
    await store.append(_pattern(0, 200), durability: Durability.fsync);
    await store.truncate(upToOffset: 100);
    await store.close();

    final leftovers = _tmp
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .where((n) => n.contains('.compact'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('a stale temp file from a crashed truncate is discarded', () async {
    final store = await IoWalStore.open(_path('h.wal'));
    await store.append(_pattern(0, 200), durability: Durability.fsync);
    // Simulate a crash between staging and rename: a leftover temp file
    // holding garbage. It must not contaminate the next truncate.
    await File('${_path('h.wal')}.compact')
        .writeAsBytes(_pattern(240, 32), flush: true);

    await store.truncate(upToOffset: 100);

    expect(store.length, 100);
    expect(await _readAll(store), _pattern(100, 100));
    await store.close();
  });

  group('concurrent operations queue behind a truncate', () {
    // `truncate` closes and reopens the append handle around its rename.
    // Anything touching that handle concurrently — most realistically the
    // group-commit `sync()` from `WalWriter` — must wait rather than
    // observe the closed handle. This used to surface as a spurious
    // "WalStore is closed" (or a raw FileSystemException before the
    // truncate was made atomic).
    test('sync during a truncate does not fail', () async {
      final store = await IoWalStore.open(_path('race_sync.wal'));
      await store.append(_pattern(0, 300 * 1024),
          durability: Durability.fsync);

      final truncating = store.truncate(upToOffset: 100 * 1024);
      final syncing = store.sync();
      await expectLater(Future.wait([truncating, syncing]), completes);

      expect(store.length, 200 * 1024);
      expect(await _readAll(store), _pattern(100 * 1024, 200 * 1024));
      await store.close();
    });

    test('append during a truncate lands after the retained tail',
        () async {
      final store = await IoWalStore.open(_path('race_append.wal'));
      await store.append(_pattern(0, 200 * 1024),
          durability: Durability.fsync);

      final truncating = store.truncate(upToOffset: 100 * 1024);
      final appending =
          store.append(_pattern(11, 16), durability: Durability.fsync);
      await Future.wait([truncating, appending]);

      expect(store.length, 100 * 1024 + 16);
      expect(
        await _readAll(store),
        Uint8List.fromList(
            [..._pattern(100 * 1024, 100 * 1024), ..._pattern(11, 16)]),
      );
      await store.close();
    });

    test('close waits for an in-flight truncate', () async {
      final store = await IoWalStore.open(_path('race_close.wal'));
      await store.append(_pattern(0, 200 * 1024),
          durability: Durability.fsync);
      final truncating = store.truncate(upToOffset: 100 * 1024);
      final closing = store.close();
      await expectLater(Future.wait([truncating, closing]), completes);
    });
  });

  test('the WAL stays replayable across a truncate', () async {
    const codec = WalCodec();
    final store = await IoWalStore.open(_path('i.wal'));
    // Two framed transactions; drop the first, keep the second.
    final first = codec.encodeFramed(
        const SequencedWalOp(lsn: 0, txnId: 1, op: BeginTxn()));
    final firstCommit = codec.encodeFramed(
        SequencedWalOp(lsn: 1, txnId: 1, op: const CommitTxn(1)));
    await store.append(first, durability: Durability.fsync);
    await store.append(firstCommit, durability: Durability.fsync);
    final boundary = store.length;
    final second = codec.encodeFramed(
        const SequencedWalOp(lsn: 2, txnId: 2, op: BeginTxn()));
    final secondCommit = codec.encodeFramed(
        SequencedWalOp(lsn: 3, txnId: 2, op: const CommitTxn(3)));
    await store.append(second, durability: Durability.fsync);
    await store.append(secondCommit, durability: Durability.fsync);

    await store.truncate(upToOffset: boundary);

    final replayed = <SequencedWalOp>[];
    await for (final op in WalReader(store, codec: codec).replay()) {
      replayed.add(op);
    }
    expect(replayed.map((o) => o.lsn), [2, 3]);
    expect(replayed.map((o) => o.txnId), [2, 2]);
    await store.close();
  });
}
