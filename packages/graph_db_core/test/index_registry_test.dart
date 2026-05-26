@TestOn('vm')
library;

import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_core/src/secondary_index/index_registry.dart';
import 'package:test/test.dart';

/// A2 — `IndexRegistry` unit tests.
///
/// The whole point of the extraction is that the registry depends only
/// on a [PropertyStore] (+ two closures), with **no back-reference to
/// `MutableGraphState`**. These tests build a registry against a bare
/// `PropertyStore` — never a `GraphDb` or `MutableGraphState` — proving
/// the seam is testable in isolation.
void main() {
  // Registry wired to a bare property store. `csrSizeBytes` is a fixed
  // stub (the size-budget ratio is the only thing it feeds) and no
  // rebuild coordinator is attached (sync flush path).
  ({IndexRegistry registry, PropertyStore nodeProps}) makeRegistry({
    int vidSpace = 64,
    int csrSizeBytes = 1 << 20, // 1 MiB — big enough that no size event fires
  }) {
    final nodeProps = PropertyStore(vidSpace: vidSpace);
    final edgeProps = PropertyStore(vidSpace: vidSpace);
    final registry = IndexRegistry(
      nodeProps: nodeProps,
      edgeProps: edgeProps,
      coordinator: () => null,
      csrSizeBytes: () => csrSizeBytes,
    );
    return (registry: registry, nodeProps: nodeProps);
  }

  group('A2: IndexRegistry in isolation (no MutableGraphState)', () {
    test('builds an index over an existing column and looks it up by name', () {
      final (:registry, :nodeProps) = makeRegistry();
      const ageKey = 0;
      nodeProps.createColumn(ageKey, ColumnType.int_);
      nodeProps.setInt(0, ageKey, 30);
      nodeProps.setInt(1, ageKey, 40);

      final idx = registry.createNodeIndex(IndexSpec(
        name: 'age',
        keyId: ageKey,
        kind: const EqualityRange(),
      )) as IntEqualityRangeIndex;

      expect(idx.length, 2);
      expect(identical(registry.getNode('age'), idx), isTrue);
      expect(registry.nodeIndexes.keys, contains('age'));
      // Edge namespace is independent.
      expect(registry.getEdge('age'), isNull);
    });

    test('duplicate index name throws ConstraintViolation', () {
      final (:registry, :nodeProps) = makeRegistry();
      nodeProps.createColumn(0, ColumnType.int_);
      registry.createNodeIndex(
          IndexSpec(name: 'k', keyId: 0, kind: const EqualityRange()));
      expect(
        () => registry.createNodeIndex(
            IndexSpec(name: 'k', keyId: 0, kind: const EqualityRange())),
        throwsA(isA<ConstraintViolation>()),
      );
    });

    test('afterNodeWrite drop-and-rebuilds a default index', () {
      final (:registry, :nodeProps) = makeRegistry();
      const ageKey = 0;
      nodeProps.createColumn(ageKey, ColumnType.int_);
      nodeProps.setInt(0, ageKey, 30);
      final first = registry.createNodeIndex(
          IndexSpec(name: 'age', keyId: ageKey, kind: const EqualityRange()));
      expect(first.length, 1);

      // New write + maintain → a fresh index object reflecting both vids.
      nodeProps.setInt(1, ageKey, 40);
      registry.afterNodeWrite(1, ageKey);
      final rebuilt = registry.getNode('age')!;
      expect(identical(rebuilt, first), isFalse);
      expect(rebuilt.length, 2);
    });

    test('afterNodeWrite updates an incremental int index in place', () {
      final (:registry, :nodeProps) = makeRegistry();
      const ageKey = 0;
      nodeProps.createColumn(ageKey, ColumnType.int_);
      final idx = registry.createNodeIndex(IndexSpec(
        name: 'age',
        keyId: ageKey,
        kind: const EqualityRange(incremental: true),
      )) as IntEqualityRangeIndex;

      nodeProps.setInt(0, ageKey, 30);
      registry.afterNodeWrite(0, ageKey);
      nodeProps.setInt(1, ageKey, 40);
      registry.afterNodeWrite(1, ageKey);

      // Same object — incremental, not drop-and-rebuild.
      expect(identical(registry.getNode('age'), idx), isTrue);
      expect(idx.length, 2);
      expect(idx.lowerBound(40), 1);
    });

    test('beforeNodeWrite enforces a unique index', () {
      final (:registry, :nodeProps) = makeRegistry();
      const emailKey = 0;
      nodeProps.createColumn(emailKey, ColumnType.stringId);
      registry.createNodeIndex(IndexSpec(
        name: 'email',
        keyId: emailKey,
        kind: const EqualityRange(unique: true),
      ));
      // vid 0 takes value 7; index it.
      nodeProps.setStringId(0, emailKey, 7);
      registry.afterNodeWrite(0, emailKey);

      // A different vid claiming the same value is rejected.
      expect(
        () => registry.beforeNodeWrite(1, emailKey, const PropInt(7)),
        throwsA(isA<ConstraintViolation>()),
      );
      // The same vid re-writing its own value is allowed.
      registry.beforeNodeWrite(0, emailKey, const PropInt(7));
    });

    test('onNodeDeleted removes the vid from an incremental int index', () {
      final (:registry, :nodeProps) = makeRegistry();
      const ageKey = 0;
      nodeProps.createColumn(ageKey, ColumnType.int_);
      final idx = registry.createNodeIndex(IndexSpec(
        name: 'age',
        keyId: ageKey,
        kind: const EqualityRange(incremental: true),
      )) as IntEqualityRangeIndex;
      for (var v = 0; v < 3; v++) {
        nodeProps.setInt(v, ageKey, 10 + v);
        registry.afterNodeWrite(v, ageKey);
      }
      expect(idx.length, 3);

      nodeProps.removeAllForVid(1);
      registry.onNodeDeleted(1);
      expect(identical(registry.getNode('age'), idx), isTrue);
      expect(idx.length, 2);
    });

    test('deferred index queues on afterNodeWrite, drains on flush', () {
      final (:registry, :nodeProps) = makeRegistry();
      const ageKey = 0;
      nodeProps.createColumn(ageKey, ColumnType.int_);
      registry.createNodeIndex(IndexSpec(
        name: 'age',
        keyId: ageKey,
        kind: const EqualityRange(deferred: true),
      ));
      nodeProps.setInt(0, ageKey, 30);
      registry.afterNodeWrite(0, ageKey);
      expect(registry.pendingDeferredIndexUpdates, 1);

      registry.flushDeferredIndexUpdates();
      expect(registry.pendingDeferredIndexUpdates, 0);
      expect(registry.getNode('age')!.length, 1);
    });

    test('createNodeIndex fires the size event over the soft budget', () {
      // Tiny CSR so a handful of indexed ints blow past the 25 % ratio.
      final (:registry, :nodeProps) = makeRegistry(csrSizeBytes: 16);
      const ageKey = 0;
      nodeProps.createColumn(ageKey, ColumnType.int_);
      for (var v = 0; v < 8; v++) {
        nodeProps.setInt(v, ageKey, v);
      }
      IndexSizeEvent? caught;
      registry.createNodeIndex(
        IndexSpec(name: 'age', keyId: ageKey, kind: const EqualityRange()),
        onSizeEvent: (e) => caught = e,
      );
      expect(caught, isNotNull);
      expect(caught!.severity, IndexSizeSeverity.warn);
    });

    test('dropNode removes the index and returns it', () {
      final (:registry, :nodeProps) = makeRegistry();
      nodeProps.createColumn(0, ColumnType.int_);
      final created = registry.createNodeIndex(
          IndexSpec(name: 'k', keyId: 0, kind: const EqualityRange()));
      expect(registry.dropNode('k'), same(created));
      expect(registry.getNode('k'), isNull);
      expect(registry.dropNode('k'), isNull);
    });
  });
}
