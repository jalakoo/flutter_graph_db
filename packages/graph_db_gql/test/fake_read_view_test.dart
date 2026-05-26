import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

/// A3.3 — the payoff of the `GraphReadView` seam: the executor runs
/// against a hand-written fake, with **no `GraphDb` and no WAL store**
/// constructed anywhere in this file. Before A3 this was impossible — the
/// executor reached into the engine's `csr`/`overlay`/`nodeProps`, so a real
/// engine was mandatory. Now a ~30-line fake exercises the full read path.
class _FakeReadView implements GraphReadView {
  final Map<String, int> labelIds;
  final Map<String, int> edgeTypeIds;
  final Map<String, int> propKeyIds;
  final Map<int, String> labelNames;
  final List<int> vids;
  final Map<int, Set<int>> labels;
  final Map<int, Map<int, PropValue>> props;
  final Map<int, List<(int dst, int eid, int et)>> outEdges;

  _FakeReadView({
    this.labelIds = const {},
    this.edgeTypeIds = const {},
    this.propKeyIds = const {},
    this.labelNames = const {},
    this.vids = const [],
    this.labels = const {},
    this.props = const {},
    this.outEdges = const {},
  });

  @override
  Iterable<Vid> scanNodes() => vids.map(Vid.new);

  @override
  Iterable<Vid> labelScanAll(List<int> ls) => vids
      .where((v) => ls.every((l) => (labels[v] ?? const <int>{}).contains(l)))
      .map(Vid.new);

  @override
  void forEachOutNeighbor(
    Vid v,
    void Function(Vid dst, Eid eid, int edgeType) visit,
  ) {
    for (final (dst, eid, et) in outEdges[v.value] ?? const <(int, int, int)>[]) {
      visit(Vid(dst), Eid(eid), et);
    }
  }

  @override
  void forEachInNeighbor(
    Vid v,
    void Function(Vid src, Eid eid, int edgeType) visit,
  ) {
    for (final e in outEdges.entries) {
      for (final (dst, eid, et) in e.value) {
        if (dst == v.value) visit(Vid(e.key), Eid(eid), et);
      }
    }
  }

  @override
  Iterable<int> labelsOf(Vid v) => labels[v.value] ?? const <int>{};

  @override
  bool hasLabel(Vid v, int labelId) =>
      (labels[v.value] ?? const <int>{}).contains(labelId);

  @override
  PropValue? nodeProp(Vid v, int keyId) =>
      (props[v.value] ?? const <int, PropValue>{})[keyId];

  @override
  PropValue? edgeProp(Eid eid, int keyId) => null;

  @override
  int? labelId(String name) => labelIds[name];
  @override
  int? edgeTypeId(String name) => edgeTypeIds[name];
  @override
  int? propKeyId(String name) => propKeyIds[name];
  @override
  String? labelName(int id) => labelNames[id];
}

void main() {
  group('A3.3: GqlExecutor against a fake GraphReadView (no GraphDb)', () {
    const person = 1, knows = 10, nameKey = 100;

    _FakeReadView fake() => _FakeReadView(
          labelIds: {'Person': person},
          edgeTypeIds: {'KNOWS': knows},
          propKeyIds: {'name': nameKey},
          labelNames: {person: 'Person'},
          vids: [0, 1, 2],
          labels: {
            0: {person},
            1: {person},
            2: {person},
          },
          props: {
            0: {nameKey: const PropString('alice')},
            1: {nameKey: const PropString('bob')},
            2: {nameKey: const PropString('carol')},
          },
          // 0 -KNOWS-> 1, 1 -KNOWS-> 2
          outEdges: {
            0: [(1, 500, knows)],
            1: [(2, 501, knows)],
          },
        );

    test('NodeScan(:Person) -[:KNOWS]-> Expand + Project', () async {
      // MATCH (n:Person)-[:KNOWS]->(m) RETURN n.name AS from, m.name AS to
      final plan = Project(
        source: Expand(
          source: const NodeScan(alias: 'n', labelIds: [person]),
          fromAlias: 'n',
          toAlias: 'm',
          relAlias: null,
          edgeTypeId: knows,
          direction: Direction.outgoing,
        ),
        items: [
          ReturnItem(
            expr: PropertyAccessExpr(IdentifierExpr('n'), 'name'),
            alias: 'from',
          ),
          ReturnItem(
            expr: PropertyAccessExpr(IdentifierExpr('m'), 'name'),
            alias: 'to',
          ),
        ],
        columnNames: const ['from', 'to'],
      );

      final result = await GqlExecutor(fake()).materialize(plan, const {});

      expect(result.columns, ['from', 'to']);
      expect(
        result.rows.map((r) => (r.values['from'], r.values['to'])).toSet(),
        {('alice', 'bob'), ('bob', 'carol')},
      );
    });

    test('full NodeScan (no label) streams every visible vid', () async {
      final plan = Project(
        source: const NodeScan(alias: 'n', labelIds: null),
        items: [ReturnItem(expr: IdentifierExpr('n'), alias: 'n')],
        columnNames: const ['n'],
      );

      final result = await GqlExecutor(fake()).materialize(plan, const {});
      expect(result.rows.length, 3);
      expect(result.rows.map((r) => (r.values['n'] as Vid).value).toSet(),
          {0, 1, 2});
    });
  });
}
