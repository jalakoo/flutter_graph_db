import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// Covers the smaller engine fixes: the closed-engine write gate, the
/// `afterCommit` hook on the bulk path, and the unboxed finders.

GraphDb _db({WalSink? sink}) => GraphDb.fromState(
      MutableGraphState.fromFixture(
        nodeCount: 0,
        srcs: Uint32List(0),
        dsts: Uint32List(0),
        edgeTypes: Uint32List(0),
        labelOf: Uint32List(0),
        labelNames: const ['P'],
        edgeTypeNames: const ['R'],
        vidSpace: 16,
        eidSpace: 16,
      ),
      sink: sink,
    );

class _NoopSink implements WalSink {
  int closeCount = 0;
  @override
  Future<void> append(SequencedWalOp op, {required Durability durability}) async {}
  @override
  Future<void> appendBatch(List<SequencedWalOp> ops,
      {required Durability durability}) async {}
  @override
  Future<void> sync() async {}
  @override
  Future<void> close() async => closeCount++;
}

void main() {
  group('closed-engine write gate', () {
    test('runTransaction after close throws', () async {
      final db = _db();
      final p = db.internLabel('P');
      await db.runTransaction((t) => t.addNode(labelIds: [p]));
      await db.close();
      expect(db.isClosed, isTrue);
      await expectLater(
        db.runTransaction((t) => t.addNode(labelIds: [p])),
        throwsA(isA<StateError>()),
      );
    });

    test('bulkAddEdges after close throws', () async {
      final db = _db();
      final p = db.internLabel('P');
      final r = db.internEdgeType('R');
      final a = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      final b = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      await db.close();
      await expectLater(
        db.bulkAddEdges([BulkEdge(src: a, dst: b, typeId: r)]),
        throwsA(isA<StateError>()),
      );
    });

    test('reads still work after close', () async {
      final db = _db();
      final p = db.internLabel('P');
      final a = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      await db.close();
      expect(db.isNodeVisible(a), isTrue);
      expect(db.labelScan(p), [a.value]);
    });

    test('close stays idempotent and closes the sink once', () async {
      final sink = _NoopSink();
      final db = _db(sink: sink);
      await db.close();
      await db.close();
      await db.close();
      expect(sink.closeCount, 1);
    });
  });

  group('afterCommit', () {
    test('fires for bulkAddEdges', () async {
      final db = _db();
      final p = db.internLabel('P');
      final r = db.internEdgeType('R');
      final a = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      final b = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      var hits = 0;
      db.afterCommit = () => hits++;
      await db.bulkAddEdges([
        BulkEdge(src: a, dst: b, typeId: r),
        BulkEdge(src: b, dst: a, typeId: r),
      ]);
      expect(hits, 1, reason: 'one hook call for the whole batch');
      expect(db.edgeCount, 2);
    });

    test('does not fire for an empty bulkAddEdges', () async {
      final db = _db();
      var hits = 0;
      db.afterCommit = () => hits++;
      await db.bulkAddEdges(const []);
      expect(hits, 0);
    });

    test('bulkAddEdges leaves the read guard clear', () async {
      final db = _db();
      final p = db.internLabel('P');
      final r = db.internEdgeType('R');
      final a = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      final b = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      await db.bulkAddEdges([BulkEdge(src: a, dst: b, typeId: r)]);
      // A high-level read straight after the bulk path must not trip the
      // in-transaction read guard.
      expect(db.outDegree(a), 1);
      expect(db.edgeCount, 1);
    });
  });

  group('finders compare against the raw column', () {
    test('string equality', () async {
      final db = _db();
      final p = db.internLabel('P');
      final name = db.internPropKey('name');
      final a = await db.runTransaction((t) =>
          t.addNode(labelIds: [p], props: {name: const PropString('Ada')}));
      await db.runTransaction((t) =>
          t.addNode(labelIds: [p], props: {name: const PropString('Bob')}));
      expect(db.findNodeByProp(name, const PropString('Ada')), a);
      expect(db.findNodeByProp(name, const PropString('Zoe')), isNull);
      expect(db.findNodesByProp(name, const PropString('Ada')), [a]);
    });

    test('int, double and bool equality', () async {
      final db = _db();
      final p = db.internLabel('P');
      final n = db.internPropKey('n');
      final d = db.internPropKey('d');
      final flag = db.internPropKey('flag');
      final v = await db.runTransaction((t) => t.addNode(labelIds: [p], props: {
            n: const PropInt(42),
            d: const PropDouble(1.5),
            flag: const PropBool(true),
          }));
      expect(db.findNodeByProp(n, const PropInt(42)), v);
      expect(db.findNodeByProp(d, const PropDouble(1.5)), v);
      expect(db.findNodeByProp(flag, const PropBool(true)), v);
      expect(db.findNodeByProp(n, const PropInt(43)), isNull);
      expect(db.findNodeByProp(flag, const PropBool(false)), isNull);
    });

    test('label scoping', () async {
      final db = _db();
      final p = db.internLabel('P');
      final q = db.internLabel('Q');
      final name = db.internPropKey('name');
      await db.runTransaction((t) =>
          t.addNode(labelIds: [p], props: {name: const PropString('dup')}));
      final inQ = await db.runTransaction((t) =>
          t.addNode(labelIds: [q], props: {name: const PropString('dup')}));
      expect(db.findNodeByProp(name, const PropString('dup'), label: q), inQ);
      expect(db.findNodesByProp(name, const PropString('dup')).length, 2);
    });

    test('a type mismatch matches nothing instead of throwing', () async {
      final db = _db();
      final p = db.internLabel('P');
      final name = db.internPropKey('name');
      await db.runTransaction((t) =>
          t.addNode(labelIds: [p], props: {name: const PropString('Ada')}));
      // `name` is a string column; an int query cannot match.
      expect(db.findNodeByProp(name, const PropInt(1)), isNull);
      expect(db.findNodesByProp(name, const PropInt(1)), isEmpty);
    });

    test('an undeclared key matches nothing', () {
      final db = _db();
      final ghost = db.internPropKey('never-written');
      expect(db.findNodeByProp(ghost, const PropString('x')), isNull);
    });

    test('an absent property never matches a non-null query', () async {
      final db = _db();
      final p = db.internLabel('P');
      final name = db.internPropKey('name');
      await db.runTransaction((t) =>
          t.addNode(labelIds: [p], props: {name: const PropString('Ada')}));
      final bare = await db.runTransaction((t) => t.addNode(labelIds: [p]));
      expect(db.findNodesByProp(name, const PropString('Ada')).contains(bare),
          isFalse);
    });

    test('an explicit NULL is findable with PropNull', () async {
      final db = _db();
      final p = db.internLabel('P');
      final name = db.internPropKey('name');
      db.declareNodeColumn(name, ColumnType.string);
      final nulled = await db.runTransaction(
          (t) => t.addNode(labelIds: [p], props: {name: const PropNull()}));
      await db.runTransaction((t) =>
          t.addNode(labelIds: [p], props: {name: const PropString('Ada')}));
      expect(db.findNodeByProp(name, const PropNull()), nulled);
    });

    test('deleted nodes are not returned', () async {
      final db = _db();
      final p = db.internLabel('P');
      final name = db.internPropKey('name');
      final a = await db.runTransaction((t) =>
          t.addNode(labelIds: [p], props: {name: const PropString('Ada')}));
      await db.runTransaction((t) => t.delNode(a));
      expect(db.findNodeByProp(name, const PropString('Ada')), isNull);
      db.mergeNow();
      expect(db.findNodeByProp(name, const PropString('Ada')), isNull);
    });
  });
}
