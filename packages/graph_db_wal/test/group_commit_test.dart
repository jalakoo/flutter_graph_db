import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

/// A [WalStore] proxy that counts fsync calls — used to prove that
/// group-commit coalesces multiple txn fsyncs into one.
class _CountingStore implements WalStore {
  final WalStore _inner;
  int syncCount = 0;
  _CountingStore(this._inner);

  @override
  Future<void> append(
    Uint8List bytes, {
    required Durability durability,
  }) =>
      _inner.append(bytes, durability: durability);

  @override
  Stream<Uint8List> read({int fromOffset = 0}) =>
      _inner.read(fromOffset: fromOffset);

  @override
  int get length => _inner.length;

  @override
  Future<int> truncate({required int upToOffset}) =>
      _inner.truncate(upToOffset: upToOffset);

  @override
  Future<void> sync() async {
    syncCount++;
    await _inner.sync();
  }

  @override
  Future<void> close() => _inner.close();
}

GraphDb _dbWith({
  required _CountingStore store,
  Duration groupWindow = const Duration(milliseconds: 1),
}) {
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const [],
    edgeTypeNames: const [],
    vidSpace: 16,
    eidSpace: 16,
  );
  final writer = WalWriter(store, groupWindow: groupWindow);
  return GraphDb.fromState(state, sink: writer);
}

void main() {
  group('group-commit (plan §6.7)', () {
    test('per-txn fsync (Durability.fsync) calls sync once per commit',
        () async {
      final inner = InMemoryWalStore();
      final store = _CountingStore(inner);
      final db = _dbWith(store: store);
      for (var i = 0; i < 5; i++) {
        await db.runTransaction(
          (txn) => txn.addNode(labelIds: [db.internLabel('L')]),
          durability: Durability.fsync,
        );
      }
      // 5 commits → 5 fsyncs. (Plus possibly 1 for the catalog flush
      // on close, but we don't close yet.)
      expect(store.syncCount, 5);
    });

    test('group-commit at the sink layer coalesces concurrent appenders',
        () async {
      // GraphDb is single-writer (plan §2.3) — its commits serialize
      // via the activeTxnId guard, so they each pay a separate
      // fsync. The group-commit *value* is at the sink layer when
      // multiple appenders (Phase 6+ multi-writer / Phase 5 deferred
      // index builds) queue concurrently inside the same window.
      // Verify the coalescing at the sink layer directly.
      final inner = InMemoryWalStore();
      final store = _CountingStore(inner);
      final writer = WalWriter(store);
      final futures = <Future<void>>[];
      for (var i = 0; i < 5; i++) {
        futures.add(writer.appendBatch(
          [
            SequencedWalOp(
              lsn: i,
              txnId: i + 1,
              op: const InternString(
                intId: 0,
                value: 'x',
                kind: StringKind.label,
              ),
            ),
          ],
          durability: Durability.group,
        ));
      }
      await Future.wait(futures);
      // 5 concurrent appendBatch calls land in the same 1 ms window
      // and share one fsync. (We accept up to 2 fsyncs to tolerate
      // a rare schedule where the timer fires between calls.)
      expect(store.syncCount, lessThanOrEqualTo(2));
      expect(store.syncCount, greaterThan(0));
      await writer.close();
    });

    test('GraphDb single-writer pays one fsync per group-commit txn',
        () async {
      final inner = InMemoryWalStore();
      final store = _CountingStore(inner);
      final db = _dbWith(store: store);
      final lbl = db.internLabel('L');
      // Sequential await — single-writer guarantees they serialize,
      // so each pays its own fsync. Group-commit's benefit here is
      // batching multiple OPS within ONE txn into one fsync (already
      // covered by Durability.fsync == count == n commits).
      for (var i = 0; i < 5; i++) {
        await db.runTransaction(
          (txn) => txn.addNode(labelIds: [lbl]),
          durability: Durability.group,
        );
      }
      // 5 commits = 5 fsyncs (+1 for the initial intern label).
      // Group-commit doesn't coalesce because each commit waits for
      // its own group ack before returning, and the next can't start.
      expect(store.syncCount, 5);
    });

    test('Durability.none never syncs (warning: data not durable)',
        () async {
      final inner = InMemoryWalStore();
      final store = _CountingStore(inner);
      final db = _dbWith(store: store);
      for (var i = 0; i < 3; i++) {
        await db.runTransaction(
          (txn) => txn.addNode(labelIds: [db.internLabel('L')]),
          durability: Durability.none,
        );
      }
      expect(store.syncCount, 0);
    });

    test('GraphDb.close drains pending group ack + does a safety sync',
        () async {
      final inner = InMemoryWalStore();
      final store = _CountingStore(inner);
      // Short group window so the test doesn't take a full second.
      final db = _dbWith(store: store);
      await db.runTransaction(
        (txn) => txn.addNode(labelIds: [db.internLabel('L')]),
        durability: Durability.group,
      );
      final beforeClose = store.syncCount;
      expect(beforeClose, greaterThanOrEqualTo(1));
      await db.close();
      // Close calls sync() defensively — at least one more fsync to
      // guarantee anything buffered post-commit reaches the store.
      expect(store.syncCount, greaterThanOrEqualTo(beforeClose + 1));
    });
  });

  group('SegmentedInMemoryWalStore (plan §6.2)', () {
    test('rotates segments at the configured boundary', () async {
      final store = SegmentedInMemoryWalStore(segmentSize: 64);
      // Append four 20-byte payloads → 60 bytes in the first segment,
      // then rotation, then 20 bytes in segment 2.
      for (var i = 0; i < 4; i++) {
        await store.append(
          Uint8List(20),
          durability: Durability.none,
        );
      }
      expect(store.length, 80);
      expect(store.closedSegmentCount, 1);
      expect(store.activeSegmentFill, 20);
    });

    test('reads concatenate segments in order', () async {
      final store = SegmentedInMemoryWalStore(segmentSize: 16);
      final payloads = [
        Uint8List.fromList([1, 2, 3, 4, 5]),
        Uint8List.fromList([6, 7, 8, 9, 10]),
        Uint8List.fromList([11, 12, 13, 14, 15]),
        Uint8List.fromList([16, 17, 18, 19, 20]),
      ];
      for (final p in payloads) {
        await store.append(p, durability: Durability.none);
      }
      final all = <int>[];
      await for (final chunk in store.read()) {
        all.addAll(chunk);
      }
      expect(all, [
        1, 2, 3, 4, 5,
        6, 7, 8, 9, 10,
        11, 12, 13, 14, 15,
        16, 17, 18, 19, 20,
      ]);
    });

    test('truncate is segment-aligned (drops only whole segments)',
        () async {
      final store = SegmentedInMemoryWalStore(segmentSize: 10);
      // Three full segments of 10 bytes each + a 3-byte tail in the
      // active segment.
      for (var i = 0; i < 4; i++) {
        await store.append(Uint8List(i == 3 ? 3 : 10),
            durability: Durability.none);
      }
      expect(store.closedSegmentCount, 3);
      // Truncate up to byte 25 → drops the first two whole segments
      // (offsets 0-9 and 10-19), keeps the third (start=20).
      final newFloor = await store.truncate(upToOffset: 25);
      expect(newFloor, 20);
      expect(store.closedSegmentCount, 1);
    });

    test('frames larger than segmentSize get their own segment', () async {
      final store = SegmentedInMemoryWalStore(segmentSize: 16);
      await store.append(Uint8List(100), durability: Durability.none);
      expect(store.length, 100);
      expect(store.closedSegmentCount, 1);
    });
  });
}
