import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_remote/graph_db_remote.dart';
import 'package:graph_db_sync/graph_db_sync.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

/// Records every bulkImport call; optionally throws on the next.
class FakeRemoteClient implements RemoteGraphClient {
  bool throwNextImport = false;
  RemoteException nextImportException =
      const RemoteConstraintViolation('test-rejected');
  final List<List<ImportOp>> importBatches = [];

  @override
  CapabilityFlags get capabilities => CapabilityFlags.fake;

  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}

  @override
  Future<RemoteQueryResult> executeQuery(
    String query,
    Map<String, Object?> params,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<T> runInTransaction<T>(
    Future<T> Function(RemoteTxn) body,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<ImportResult> bulkImport(Stream<ImportOp> ops) async {
    if (throwNextImport) {
      throwNextImport = false;
      throw nextImportException;
    }
    final list = await ops.toList();
    importBatches.add(list);
    var nodes = 0, edges = 0;
    for (final o in list) {
      if (o is ImportNode) nodes++;
      if (o is ImportEdge) edges++;
    }
    return ImportResult(
      nodesImported: nodes,
      edgesImported: edges,
      elapsed: Duration.zero,
    );
  }

  @override
  Stream<GraphElement> bulkExport(SubgraphSpec spec) async* {}
}

Future<({GraphDb db, WalStore store})> _seededDb() async {
  final store = InMemoryWalStore();
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
  final knowsType = db.internEdgeType('KNOWS');
  final nameKey = db.internPropKey('name');
  late Vid alice, bob;
  await db.runTransaction((txn) {
    alice = txn.addNode(
      labelIds: [personLabel],
      props: {nameKey: const PropString('Alice')},
      logicalId: 'u-alice',
    );
    bob = txn.addNode(
      labelIds: [personLabel],
      props: {nameKey: const PropString('Bob')},
      logicalId: 'u-bob',
    );
    txn.addEdge(
      src: alice,
      dst: bob,
      typeId: knowsType,
      logicalId: 'e-1',
    );
  }, durability: Durability.fsync);
  return (db: db, store: store);
}

void main() {
  group('SyncEngine — push-only (plan §10 / §14 Phase 7)', () {
    test('syncOnce ships every committed WAL op past HWM', () async {
      final s = await _seededDb();
      final remote = FakeRemoteClient();
      final engine = SyncEngine(
        db: s.db,
        walStore: s.store,
        targets: [SyncTarget(name: 't1', client: remote)],
      );
      final reports = await engine.syncOnce();
      expect(reports.length, 1);
      final r = reports.single;
      expect(r.opsShipped, 3); // 2 AddNode + 1 AddEdge
      expect(r.opsQuarantined, 0);
      expect(r.newHwm, greaterThan(r.previousHwm));
      // Remote received the ops.
      expect(remote.importBatches.length, 1);
      expect(remote.importBatches.single.length, 3);
    });

    test('HWM resume — second syncOnce ships only the new ops', () async {
      final s = await _seededDb();
      final remote = FakeRemoteClient();
      final target = SyncTarget(name: 't1', client: remote);
      final engine = SyncEngine(
        db: s.db,
        walStore: s.store,
        targets: [target],
      );
      // First sync — ships everything.
      await engine.syncOnce();
      final hwmAfterFirst = target.hwm;

      // New writes.
      final personLabel = s.db.state.strings.labelIdOf('Person')!;
      await s.db.runTransaction((txn) {
        txn.addNode(
          labelIds: [personLabel],
          logicalId: 'u-charlie',
        );
      }, durability: Durability.fsync);

      // Second sync — ships only the new node.
      await engine.syncOnce();
      expect(target.hwm, greaterThan(hwmAfterFirst));
      expect(remote.importBatches.last.length, 1);
      expect(
        (remote.importBatches.last.single as ImportNode).logicalId,
        'u-charlie',
      );
    });

    test('quarantine on remote rejection', () async {
      final s = await _seededDb();
      final remote = FakeRemoteClient()..throwNextImport = true;
      final target = SyncTarget(name: 't1', client: remote);
      final engine = SyncEngine(
        db: s.db,
        walStore: s.store,
        targets: [target],
      );
      final reports = await engine.syncOnce();
      final r = reports.single;
      expect(r.opsShipped, 0);
      expect(r.opsQuarantined, 3);
      expect(target.quarantine.length, 1); // one batch
      expect(target.quarantine.single.reason,
          isA<RemoteConstraintViolation>());
      // HWM unchanged (no successful ship).
      expect(target.hwm, -1);
    });

    test('multi-target: each target tracks its own HWM', () async {
      final s = await _seededDb();
      final a = FakeRemoteClient();
      final b = FakeRemoteClient()..throwNextImport = true;
      final ta = SyncTarget(name: 'a', client: a);
      final tb = SyncTarget(name: 'b', client: b);
      final engine = SyncEngine(
        db: s.db,
        walStore: s.store,
        targets: [ta, tb],
      );
      final reports = await engine.syncOnce();
      expect(reports.length, 2);
      // Target A succeeded, advanced HWM.
      expect(ta.hwm, greaterThan(-1));
      // Target B failed, HWM unchanged.
      expect(tb.hwm, -1);
      expect(tb.quarantine.length, 1);
    });

    test('SeedingMode.fullExport pushes the local graph on first sync',
        () async {
      final s = await _seededDb();
      final remote = FakeRemoteClient();
      final target = SyncTarget(
        name: 'fresh',
        client: remote,
        seedingMode: SeedingMode.fullExport,
      );
      final engine = SyncEngine(
        db: s.db,
        walStore: s.store,
        targets: [target],
      );
      final reports = await engine.syncOnce();
      // Seeding ran + state seeded.
      expect(reports.single.seededOnThisRun, isTrue);
      expect(target.seeded, isTrue);
      // bulkImport called at least once for the seed batch (may + a
      // second time for the post-seed drain, but seed runs first
      // and dispatches the local graph).
      expect(remote.importBatches.length, greaterThanOrEqualTo(1));
      // The seed batch contains both nodes + the edge.
      final seedBatch = remote.importBatches.first;
      final nodeCount = seedBatch.whereType<ImportNode>().length;
      final edgeCount = seedBatch.whereType<ImportEdge>().length;
      expect(nodeCount, 2);
      expect(edgeCount, 1);
    });

    test('repeated sync with no new ops is a no-op', () async {
      final s = await _seededDb();
      final remote = FakeRemoteClient();
      final target = SyncTarget(name: 't', client: remote);
      final engine = SyncEngine(
        db: s.db,
        walStore: s.store,
        targets: [target],
      );
      await engine.syncOnce();
      final batchesAfterFirst = remote.importBatches.length;
      final reports = await engine.syncOnce();
      expect(reports.single.opsShipped, 0);
      expect(remote.importBatches.length, batchesAfterFirst);
    });
  });

  // ----- Multi-label rollout PR 4 (§14.9 + §19.10.3) -----

  group('unlabeled-node fallback (PR 4 / §19.10.3)', () {
    SyncEngine engineOnly() {
      final state = MutableGraphState.fromFixture(
        nodeCount: 0,
        srcs: Uint32List(0),
        dsts: Uint32List(0),
        edgeTypes: Uint32List(0),
        labelOf: Uint32List(0),
        labelNames: const [],
        edgeTypeNames: const [],
      );
      final db = GraphDb.fromState(state);
      return SyncEngine(
        db: db,
        walStore: InMemoryWalStore(),
        targets: const [],
      );
    }

    test('default fallback substitutes "unlabeled_node"', () {
      final engine = engineOnly();
      const op = ImportNode(
        logicalId: 'remote-1',
        labels: [],
        properties: {},
      );
      expect(engine.applyUnlabeledFallback(op), ['unlabeled_node']);
    });

    test('custom override is honoured', () {
      final engine = engineOnly()..unlabeledFallback = 'External';
      const op = ImportNode(
        logicalId: 'remote-2',
        labels: [],
        properties: {},
      );
      expect(engine.applyUnlabeledFallback(op), ['External']);
    });

    test('null fallback rejects with SyncException', () {
      final engine = engineOnly()..unlabeledFallback = null;
      const op = ImportNode(
        logicalId: 'remote-3',
        labels: [],
        properties: {},
      );
      expect(
        () => engine.applyUnlabeledFallback(op),
        throwsA(isA<SyncException>()),
      );
    });

    test('non-empty labels pass through unchanged', () {
      final engine = engineOnly();
      const op = ImportNode(
        logicalId: 'remote-4',
        labels: ['A', 'B'],
        properties: {},
      );
      expect(engine.applyUnlabeledFallback(op), ['A', 'B']);
    });
  });

  group('multi-label sync (PR 4 / §14.9)', () {
    test('seed pushes ImportNode.labels with full label set', () async {
      // Build a state with one multi-label node.
      final state = MutableGraphState.fromFixture(
        nodeCount: 1,
        srcs: Uint32List(0),
        dsts: Uint32List(0),
        edgeTypes: Uint32List(0),
        labelOf: Uint32List.fromList([0]),
        labelNames: const ['Person'],
        edgeTypeNames: const [],
        vidSpace: 16,
      );
      final db = GraphDb.fromState(state);
      final employee = db.internLabel('Employee');
      await db.runTransaction((txn) {
        txn.setNodeLabels(const Vid(0),
            added: [employee], removed: const []);
      });
      db.state.mergeNow();

      final remote = FakeRemoteClient();
      final target = SyncTarget(
        name: 't',
        client: remote,
        seedingMode: SeedingMode.fullExport,
      );
      final engine = SyncEngine(
        db: db,
        walStore: InMemoryWalStore(),
        targets: [target],
      );
      await engine.syncOnce();

      final n = remote.importBatches.first.whereType<ImportNode>().single;
      expect(n.labels..sort(), ['Employee', 'Person']);
    });
  });
}
