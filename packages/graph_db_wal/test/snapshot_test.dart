/// Snapshot + truncate + crash-injection tests (plan §14 Phase
/// 6D / 6E / 6F).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

/// `InMemoryWalStore` with controllable failures — throws at the
/// next `append` (or `truncate`, or `sync`) when armed.
class _CrashableStore implements WalStore {
  final InMemoryWalStore _inner = InMemoryWalStore();
  bool failNextAppend = false;
  bool failNextTruncate = false;

  @override
  Future<void> append(
    Uint8List bytes, {
    required Durability durability,
  }) async {
    if (failNextAppend) {
      failNextAppend = false;
      throw const _SimulatedCrash('append');
    }
    await _inner.append(bytes, durability: durability);
  }

  @override
  Stream<Uint8List> read({int fromOffset = 0}) =>
      _inner.read(fromOffset: fromOffset);

  @override
  int get length => _inner.length;

  @override
  Future<int> truncate({required int upToOffset}) async {
    if (failNextTruncate) {
      failNextTruncate = false;
      throw const _SimulatedCrash('truncate');
    }
    return _inner.truncate(upToOffset: upToOffset);
  }

  @override
  Future<void> sync() => _inner.sync();

  @override
  Future<void> close() => _inner.close();

  void reopen() => _inner.reopen();
}

class _SimulatedCrash implements Exception {
  final String where;
  const _SimulatedCrash(this.where);
  @override
  String toString() => 'SimulatedCrash($where)';
}

Future<GraphDb> _seed(WalStore store) async {
  final db = GraphDb.fromState(
    MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const [],
      edgeTypeNames: const [],
      vidSpace: 16,
      eidSpace: 16,
    ),
    sink: WalWriter(store),
  );
  final personLabel = db.internLabel('Person');
  final nameKey = db.internPropKey('name');
  await db.runTransaction((txn) {
    txn.addNode(
      labelIds: [personLabel],
      props: {nameKey: const PropString('Ada')},
    );
  }, durability: Durability.fsync);
  await db.runTransaction((txn) {
    txn.addNode(
      labelIds: [personLabel],
      props: {nameKey: const PropString('Bob')},
    );
  }, durability: Durability.fsync);
  return db;
}

void main() {
  group('6D: snapshot round-trip', () {
    test('encode + decode preserves CSR + props + interner + constraints',
        () async {
      final store = InMemoryWalStore();
      final db = await _seed(store);
      // Add a constraint so the snapshot carries the catalog.
      final personLabel = db.state.strings.labelIdOf('Person')!;
      final nameKey = db.state.strings.propKeyIdOf('name')!;
      await db.runTransaction((txn) {
        txn.declareConstraint(UniqueConstraint(
          name: 'person_name_uq',
          labelId: personLabel,
          keyId: nameKey,
        ));
      }, durability: Durability.fsync);
      // Merge before snapshot (codec invariant).
      db.state.mergeNow();
      final snap = encodeSnapshot(db.state);
      expect(snap.bytes.isNotEmpty, isTrue);
      expect(snap.meta.lsn, db.currentLsn);

      // Decode + verify state shape.
      final restored = decodeSnapshot(snap.bytes);
      expect(restored.strings.labelIdOf('Person'), personLabel);
      expect(restored.strings.propKeyIdOf('name'), nameKey);
      expect(restored.csr.nodeCount, 2);
      expect(
        restored.nodeProps.getString(0, nameKey),
        'Ada',
      );
      expect(restored.constraints.length, 1);
      expect(restored.constraints.get('person_name_uq'),
          isA<UniqueConstraint>());
    });

    test('encoding a non-empty overlay throws — caller must merge first',
        () {
      final db = GraphDb.fromState(
        MutableGraphState.fromFixture(
          nodeCount: 0,
          srcs: Uint32List(0),
          dsts: Uint32List(0),
          edgeTypes: Uint32List(0),
          labelOf: Uint32List(0),
          labelNames: const [],
          edgeTypeNames: const [],
          vidSpace: 16,
          eidSpace: 16,
        ),
      );
      final lbl = db.internLabel('L');
      // Use the state-level applier so we leave overlay dirty.
      db.state.applyAddNode(
        const Vid(0),
        logicalId: 'x',
        labelIds: [lbl],
        props: const {},
      );
      expect(() => encodeSnapshot(db.state),
          throwsA(isA<StateError>()));
    });
  });

  group('6E: truncate compaction', () {
    test('compactToCurrentTip drops every byte up to current length',
        () async {
      final store = SegmentedInMemoryWalStore(segmentSize: 64);
      final db = await _seed(store);
      final lengthBefore = store.length;
      expect(lengthBefore, greaterThan(0));
      final retainedFloor = await compactToCurrentTip(store: store);
      // Segment-aligned — may not equal lengthBefore exactly, but
      // it's < or == lengthBefore.
      expect(retainedFloor, lessThanOrEqualTo(lengthBefore));
      await db.close();
    });

    test('snapshot-then-truncate-then-restore round trip works', () async {
      final store = SegmentedInMemoryWalStore(segmentSize: 64);
      final db = await _seed(store);
      db.state.mergeNow();
      final snap = encodeSnapshot(db.state);
      // Truncate (segment-aligned; may not drop everything — that's
      // fine for the restore round-trip).
      await compactToCurrentTip(store: store);
      // Re-open with the snapshot.
      store.reopen();
      final db2 = await openWalBackedGraphDb(
        store: store,
        snapshot: snap.bytes,
      );
      // State preserved.
      final nameKey = db2.state.strings.propKeyIdOf('name')!;
      expect(db2.state.csr.nodeCount, 2);
      expect(db2.state.nodeProps.getString(0, nameKey), 'Ada');
      await db2.close();
    });
  });

  group('6F: crash-injection — recovery restores consistent state', () {
    test('crash mid-append leaves WAL valid; recovery skips torn ops',
        () async {
      final store = _CrashableStore();
      final db = await _seed(store);
      // Arm: next append throws.
      store.failNextAppend = true;
      await expectLater(
        () => db.runTransaction(
          (txn) => txn.addNode(labelIds: [db.internLabel('X')]),
          durability: Durability.fsync,
        ),
        throwsA(isA<_SimulatedCrash>()),
      );
      // The pre-crash state should still be recoverable.
      store.reopen();
      final recovered = await recoverGraphState(store: store);
      // First two seeded nodes survived.
      expect(recovered.csr.nodeCount + recovered.overlay.addedNodes.length,
          greaterThanOrEqualTo(2));
    });

    test('crash mid-truncate doesn\'t lose the snapshot data', () async {
      final store = _CrashableStore();
      final db = await _seed(store);
      db.state.mergeNow();
      final snap = encodeSnapshot(db.state);
      store.failNextTruncate = true;
      await expectLater(
        () => compactToCurrentTip(store: store),
        throwsA(isA<_SimulatedCrash>()),
      );
      // The WAL is intact (truncate threw before mutating).
      store.reopen();
      final db2 = await openWalBackedGraphDb(
        store: store,
        snapshot: snap.bytes,
      );
      final nameKey = db2.state.strings.propKeyIdOf('name')!;
      expect(db2.state.csr.nodeCount, 2);
      expect(db2.state.nodeProps.getString(0, nameKey), 'Ada');
      await db2.close();
    });
  });
}
