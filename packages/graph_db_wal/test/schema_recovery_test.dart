@TestOn('vm')
library;

import 'dart:io';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:graph_db_wal/io_wal_store.dart';
import 'package:test/test.dart';

/// Column and index declarations must survive a restart.
///
/// Regression: both were in-memory-only side effects. `declareNodeColumn`
/// and `createNodePropertyIndex` had to be repeated on every open or the
/// column came back untyped (a typed read threw until the first write
/// re-inferred it) and the index was silently absent.

void main() {
  test('a declared column keeps its type across WAL recovery', () async {
    final store = InMemoryWalStore();
    var db = await openWalBackedGraphDb(store: store);
    final score = db.internPropKey('score');
    db.declareNodeColumn(score, ColumnType.double_);
    // Force the pending schema op out to the WAL.
    await db.runTransaction(
        (t) => t.addNodeNamed(labels: const ['P']),
        durability: Durability.fsync);
    expect(db.nodePropType(score), ColumnType.double_);

    db = await openWalBackedGraphDb(store: store);

    expect(db.propKeyId('score'), score);
    expect(db.nodePropType(score), ColumnType.double_,
        reason: 'the type-lock must be restored without re-declaring');
  });

  test('a declared edge column keeps its type across WAL recovery', () async {
    final store = InMemoryWalStore();
    var db = await openWalBackedGraphDb(store: store);
    final w = db.internPropKey('w');
    db.declareEdgeColumn(w, ColumnType.int_);
    await db.runTransaction((t) => t.addNodeNamed(labels: const ['P']),
        durability: Durability.fsync);

    db = await openWalBackedGraphDb(store: store);

    expect(db.edgePropType(db.propKeyId('w')!), ColumnType.int_);
  });

  test('a re-declaration with a conflicting type is rejected', () async {
    final store = InMemoryWalStore();
    final db = await openWalBackedGraphDb(store: store);
    final k = db.internPropKey('k');
    db.declareNodeColumn(k, ColumnType.int_);
    expect(() => db.declareNodeColumn(k, ColumnType.string),
        throwsA(isA<ConstraintViolation>()));
    // The matching re-declaration is a no-op.
    expect(() => db.declareNodeColumn(k, ColumnType.int_), returnsNormally);
  });

  test('an index is rebuilt from data after WAL recovery', () async {
    final store = InMemoryWalStore();
    var db = await openWalBackedGraphDb(store: store);
    final p = db.internLabel('P');
    final age = db.internPropKey('age');
    db.declareNodeColumn(age, ColumnType.int_);
    db.createNodePropertyIndex(
        IndexSpec(name: 'by_age', keyId: age, kind: const EqualityRange()));
    final v = await db.runTransaction(
        (t) => t.addNode(labelIds: [p], props: {age: const PropInt(30)}),
        durability: Durability.fsync);

    db = await openWalBackedGraphDb(store: store);

    final idx = db.getNodeIndex('by_age');
    expect(idx, isNotNull, reason: 'the declaration must be replayed');
    expect(idx!.length, 1, reason: 'and rebuilt from the recovered column');
    expect(idx.sortedVids, [v.value]);
  });

  test('an edge index is rebuilt after WAL recovery', () async {
    final store = InMemoryWalStore();
    var db = await openWalBackedGraphDb(store: store);
    final w = db.internPropKey('w');
    db.declareEdgeColumn(w, ColumnType.int_);
    db.createEdgePropertyIndex(
        IndexSpec(name: 'by_w', keyId: w, kind: const EqualityRange()));
    await db.runTransaction((t) {
      final a = t.addNodeNamed(labels: const ['P']);
      final b = t.addNodeNamed(labels: const ['P']);
      t.addEdgeNamed(src: a, dst: b, type: 'R', props: {'w': const PropInt(4)});
    }, durability: Durability.fsync);

    db = await openWalBackedGraphDb(store: store);

    expect(db.getEdgeIndex('by_w')?.length, 1);
  });

  test('a dropped index stays dropped after recovery', () async {
    final store = InMemoryWalStore();
    var db = await openWalBackedGraphDb(store: store);
    final age = db.internPropKey('age');
    db.declareNodeColumn(age, ColumnType.int_);
    db.createNodePropertyIndex(
        IndexSpec(name: 'by_age', keyId: age, kind: const EqualityRange()));
    await db.runTransaction((t) => t.addNodeNamed(labels: const ['P']),
        durability: Durability.fsync);
    expect(db.dropNodeIndex('by_age'), isNotNull);
    await db.runTransaction((t) => t.addNodeNamed(labels: const ['P']),
        durability: Durability.fsync);

    db = await openWalBackedGraphDb(store: store);

    expect(db.getNodeIndex('by_age'), isNull);
  });

  // Uses a real file so the store can be reopened after `db.close()`
  // closes it — which is the actual app-shutdown shape.
  test('close() flushes a trailing schema declaration', () async {
    final dir = await Directory.systemTemp.createTemp('schema_close');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/w.wal';

    var store = await IoWalStore.open(path);
    var db = await openWalBackedGraphDb(store: store);
    final k = db.internPropKey('k');
    // No transaction follows — only `close()` can get this to the log.
    db.declareNodeColumn(k, ColumnType.string);
    await db.close();

    store = await IoWalStore.open(path);
    db = await openWalBackedGraphDb(store: store);

    expect(db.nodePropType(db.propKeyId('k')!), ColumnType.string);
    await db.close();
  });

  test('schema survives a snapshot-only open', () async {
    final store = InMemoryWalStore();
    final snaps = InMemorySnapshotStore();
    var db = await openWalBackedGraphDb(store: store, snapshotStore: snaps);
    final p = db.internLabel('P');
    final age = db.internPropKey('age');
    db.declareNodeColumn(age, ColumnType.int_);
    db.createNodePropertyIndex(
        IndexSpec(name: 'by_age', keyId: age, kind: const EqualityRange()));
    final v = await db.runTransaction(
        (t) => t.addNode(labelIds: [p], props: {age: const PropInt(7)}),
        durability: Durability.fsync);

    // Snapshot, then drop the whole WAL — the snapshot is now the only
    // source of truth for the schema as well as the data.
    db.mergeNow();
    final snap = db.captureSnapshot();
    await snaps.write(snap.bytes);
    await store.truncate(upToOffset: store.length);

    db = await openWalBackedGraphDb(store: store, snapshotStore: snaps);

    expect(db.nodePropType(db.propKeyId('age')!), ColumnType.int_);
    final idx = db.getNodeIndex('by_age');
    expect(idx, isNotNull);
    expect(idx!.sortedVids, [v.value]);
  });

  test('a declared-but-empty column round-trips through a snapshot', () async {
    final store = InMemoryWalStore();
    final db = await openWalBackedGraphDb(store: store);
    final k = db.internPropKey('never-written');
    db.declareNodeColumn(k, ColumnType.bool_);
    db.mergeNow();
    final restored = decodeSnapshot(db.captureSnapshot().bytes);
    expect(restored.nodeProps.columnType(k), ColumnType.bool_);
  });
}
