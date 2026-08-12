import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';
import 'package:test/test.dart';

/// `UNIQUE (Label, key)` is scoped to nodes carrying that label.
///
/// Regression: `applyDeclareConstraint` backed the constraint with a
/// *global* unique index, so a node carrying only some unrelated label
/// was rejected for duplicating a value under someone else's
/// constraint — over-rejection against Neo4j semantics.

class _Fixture {
  final GraphDb db;
  final int labelA;
  final int labelB;
  final int key;
  _Fixture(this.db, this.labelA, this.labelB, this.key);

  static Future<_Fixture> create() async {
    final db = GraphDb.fromState(MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const ['A', 'B'],
      edgeTypeNames: const [],
      vidSpace: 16,
      eidSpace: 16,
    ));
    final a = db.internLabel('A');
    final b = db.internLabel('B');
    final k = db.internPropKey('k');
    db.declareNodeColumn(k, ColumnType.string);
    await db.runTransaction((t) => t.declareConstraint(
        UniqueConstraint(name: 'uq_a_k', labelId: a, keyId: k)));
    return _Fixture(db, a, b, k);
  }

  Future<Vid> add(int label, String value) => db.runTransaction((t) =>
      t.addNode(labelIds: [label], props: {key: PropString(value)}));
}

void main() {
  test('a duplicate under the constrained label is rejected', () async {
    final f = await _Fixture.create();
    await f.add(f.labelA, 'x');
    await expectLater(
      f.add(f.labelA, 'x'),
      throwsA(isA<ConstraintViolation>()),
    );
  });

  test('the same value on a different label is allowed', () async {
    final f = await _Fixture.create();
    await f.add(f.labelA, 'x');
    final b = await f.add(f.labelB, 'x');
    expect(f.db.isNodeVisible(b), isTrue);
    expect(f.db.getNodeStringProp(b, f.key), 'x');
  });

  test('an out-of-scope duplicate does not mask an in-scope one', () async {
    final f = await _Fixture.create();
    // Seed the value on an unscoped node first so it sorts ahead of the
    // scoped one in the index — the old first-hit-only check would find
    // this row, see it out of scope, and wrongly allow the duplicate.
    await f.add(f.labelB, 'x');
    await f.add(f.labelA, 'x');
    await expectLater(
      f.add(f.labelA, 'x'),
      throwsA(isA<ConstraintViolation>()),
    );
  });

  test('multi-label nodes are in scope when they carry the label', () async {
    final f = await _Fixture.create();
    await f.db.runTransaction((t) => t.addNode(
        labelIds: [f.labelA, f.labelB], props: {f.key: const PropString('x')}));
    await expectLater(
      f.add(f.labelA, 'x'),
      throwsA(isA<ConstraintViolation>()),
    );
  });

  test('gaining the constrained label re-checks uniqueness', () async {
    final f = await _Fixture.create();
    await f.add(f.labelA, 'x');
    final b = await f.add(f.labelB, 'x');
    // b now legally holds 'x' outside the constraint. Adding label A
    // pulls it into scope and must be rejected.
    await expectLater(
      f.db.runTransaction(
          (t) => t.setNodeLabels(b, added: [f.labelA], removed: const [])),
      throwsA(isA<ConstraintViolation>()),
    );
    // The rejected label change left the node's labels untouched.
    expect(f.db.hasLabel(b, f.labelA), isFalse);
    expect(f.db.hasLabel(b, f.labelB), isTrue);
  });

  test('gaining an unrelated label is fine', () async {
    final f = await _Fixture.create();
    final a = await f.add(f.labelA, 'x');
    await f.db.runTransaction(
        (t) => t.setNodeLabels(a, added: [f.labelB], removed: const []));
    expect(f.db.hasLabel(a, f.labelA), isTrue);
    expect(f.db.hasLabel(a, f.labelB), isTrue);
  });

  test('declare-time validation still catches existing duplicates', () async {
    final db = GraphDb.fromState(MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const ['A'],
      edgeTypeNames: const [],
      vidSpace: 16,
      eidSpace: 16,
    ));
    final a = db.internLabel('A');
    final k = db.internPropKey('k');
    await db.runTransaction((t) =>
        t.addNode(labelIds: [a], props: {k: const PropString('dup')}));
    await db.runTransaction((t) =>
        t.addNode(labelIds: [a], props: {k: const PropString('dup')}));
    await expectLater(
      db.runTransaction((t) => t.declareConstraint(
          UniqueConstraint(name: 'uq', labelId: a, keyId: k))),
      throwsA(isA<ConstraintViolation>()),
    );
  });

  test('an explicitly unscoped unique index still spans every label',
      () async {
    final f = await _Fixture.create();
    f.db.createNodePropertyIndex(IndexSpec(
      name: 'global_k',
      keyId: f.key,
      kind: const EqualityRange(unique: true),
    ));
    await f.add(f.labelA, 'y');
    await expectLater(
      f.add(f.labelB, 'y'),
      throwsA(isA<ConstraintViolation>()),
    );
  });
}
