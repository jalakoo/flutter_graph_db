@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_core/src/secondary_index/index_worker.dart';
import 'package:test/test.dart';

void main() {
  group('IndexRebuildCoordinator (worker-isolate)', () {
    late IndexRebuildCoordinator coord;

    setUpAll(() async {
      coord = await IndexRebuildCoordinator.spawn();
    });

    tearDownAll(() async {
      await coord.dispose();
    });

    test('worker returns a byte-identical sorted result vs main-isolate build',
        () async {
      // Seed a state w/ an indexed int column.
      const n = 1024;
      final state = MutableGraphState.fromFixture(
        nodeCount: n,
        srcs: Uint32List(0),
        dsts: Uint32List(0),
        edgeTypes: Uint32List(0),
        labelOf: Uint32List(n),
        labelNames: const ['Person'],
        edgeTypeNames: const [],
        vidSpace: n + 16,
        eidSpace: 16,
      );
      final db = GraphDb.fromState(state);
      final ageKey = db.internPropKey('age');
      // Set ages with a deliberately non-monotone pattern.
      for (var i = 0; i < n; i++) {
        state.nodeProps.setInt(i, ageKey, (i * 7919) % 100); // pseudo-rand
      }
      // Reference (main-isolate) sorted index.
      final reference = db.createNodePropertyIndex(IndexSpec(
        name: 'age_sync',
        keyId: ageKey,
        kind: const EqualityRange(),
      )) as IntEqualityRangeIndex;

      // Worker-isolate rebuild.
      final pairs = <(int, int)>[];
      state.nodeProps.forEachSetInt(
        ageKey,
        (vid, value) => pairs.add((vid, value)),
      );
      final snap = snapshotIntColumn(pairs: pairs);
      final task = IndexRebuildIntTask.copyAndWrap(
        spec: IndexSpec(
          name: 'age_async',
          keyId: ageKey,
          kind: const EqualityRange(),
        ),
        hashOverlay: false,
        values: snap.values,
        vids: snap.vids,
      );
      final rebuilt = await coord.rebuildInt(task);
      final rebuiltIdx = buildIntIndexFromSorted(
        spec: task.spec,
        sortedValues: rebuilt.sortedValues,
        sortedVids: rebuilt.sortedVids,
        hashOverlay: false,
      );

      // Byte-identical sorted arrays.
      expect(rebuiltIdx.sortedValues, reference.sortedValues);
      expect(rebuiltIdx.sortedVids, reference.sortedVids);
    });

    test('main-isolate stall (copy + install) is bounded — Spike B carry',
        () async {
      // Larger fixture so the worker's sort time is meaningful and the
      // worker→main gap is observable.
      const n = 10000;
      final state = MutableGraphState.fromFixture(
        nodeCount: n,
        srcs: Uint32List(0),
        dsts: Uint32List(0),
        edgeTypes: Uint32List(0),
        labelOf: Uint32List(n),
        labelNames: const ['Person'],
        edgeTypeNames: const [],
        vidSpace: n + 16,
        eidSpace: 16,
      );
      final db = GraphDb.fromState(state);
      final age = db.internPropKey('age');
      for (var i = 0; i < n; i++) {
        state.nodeProps.setInt(i, age, (i * 7919) % 1000);
      }
      final pairs = <(int, int)>[];
      state.nodeProps.forEachSetInt(
        age,
        (vid, value) => pairs.add((vid, value)),
      );
      final snap = snapshotIntColumn(pairs: pairs);

      // Time the end-to-end. The worker's self-reported sort time
      // is subtracted to approximate main-isolate stall.
      final sw = Stopwatch()..start();
      final rebuilt = await coord.rebuildInt(IndexRebuildIntTask.copyAndWrap(
        spec: IndexSpec(
          name: 'stall_test',
          keyId: age,
          kind: const EqualityRange(),
        ),
        hashOverlay: false,
        values: snap.values,
        vids: snap.vids,
      ));
      sw.stop();
      final wallUs = sw.elapsedMicroseconds;
      final workerUs = coord.lastWorkerUs;
      final stallUsApprox = wallUs - workerUs;
      // The worker has to have done some sort work.
      expect(workerUs, greaterThan(0));
      // Stall (copy + install + IPC) is much smaller than worker.
      // Loose upper bound — the actual numbers on desktop are ≈ 100–
      // 500 µs depending on schedule.
      expect(stallUsApprox, lessThan(workerUs + 50000));
      // Result has the expected length.
      expect(rebuilt.sortedValues.length, n);
    });

    test('worker survives many sequential rebuilds', () async {
      const n = 256;
      final state = MutableGraphState.fromFixture(
        nodeCount: n,
        srcs: Uint32List(0),
        dsts: Uint32List(0),
        edgeTypes: Uint32List(0),
        labelOf: Uint32List(n),
        labelNames: const ['L'],
        edgeTypeNames: const [],
        vidSpace: n + 16,
        eidSpace: 16,
      );
      final db = GraphDb.fromState(state);
      final age = db.internPropKey('age');
      for (var i = 0; i < n; i++) {
        state.nodeProps.setInt(i, age, i);
      }
      final pairs = <(int, int)>[];
      state.nodeProps.forEachSetInt(
        age,
        (vid, value) => pairs.add((vid, value)),
      );
      for (var i = 0; i < 8; i++) {
        final snap = snapshotIntColumn(pairs: pairs);
        final r = await coord.rebuildInt(IndexRebuildIntTask.copyAndWrap(
          spec: IndexSpec(
            name: 'iter_$i',
            keyId: age,
            kind: const EqualityRange(),
          ),
          hashOverlay: false,
          values: snap.values,
          vids: snap.vids,
        ));
        expect(r.sortedValues.length, n);
      }
    });
  });
}
