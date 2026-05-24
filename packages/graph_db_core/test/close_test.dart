import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// `GraphDb.close()` is idempotent — calling it more than once is a
/// no-op and never re-invokes the underlying sink's `close()`.

GraphDb _emptyDb({WalSink? sink}) {
  final state = MutableGraphState.fromFixture(
    nodeCount: 0,
    srcs: Uint32List(0),
    dsts: Uint32List(0),
    edgeTypes: Uint32List(0),
    labelOf: Uint32List(0),
    labelNames: const ['Thing'],
    edgeTypeNames: const ['rel'],
    vidSpace: 16,
    eidSpace: 16,
  );
  return GraphDb.fromState(state, sink: sink);
}

/// Records how often `close()` lands and throws on the second call —
/// so an un-guarded double-close would surface as a thrown error.
class _RecordingSink implements WalSink {
  int closeCount = 0;

  @override
  Future<void> append(SequencedWalOp op, {required Durability durability}) async {}

  @override
  Future<void> appendBatch(
    List<SequencedWalOp> ops, {
    required Durability durability,
  }) async {}

  @override
  Future<void> sync() async {}

  @override
  Future<void> close() async {
    closeCount++;
    if (closeCount > 1) {
      throw StateError('sink.close() called more than once');
    }
  }
}

void main() {
  group('GraphDb.close() idempotency', () {
    test('in-memory db: a second close() is a no-op', () async {
      final db = _emptyDb();
      await db.close();
      await expectLater(db.close(), completes);
    });

    test('sink-backed db: close() reaches the sink exactly once', () async {
      final sink = _RecordingSink();
      final db = _emptyDb(sink: sink);

      await db.close();
      await expectLater(db.close(), completes); // would throw if unguarded
      await db.close();

      expect(sink.closeCount, 1,
          reason: 'the guard must stop the 2nd+ close reaching the sink');
    });
  });
}
