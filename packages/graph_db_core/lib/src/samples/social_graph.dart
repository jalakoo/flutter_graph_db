import 'dart:typed_data';

import '../graph_db.dart';
import '../ids.dart';
import '../mutable_graph_state.dart';

/// A small hand-built social graph fixture — used by the example app
/// and by tests. 12 people across 4 companies, with `knows` /
/// `worksAt` / `founded` edges and `name` / `age` / `title` / `founded`
/// properties.
///
/// Phase 1: the fixture loads through [MutableGraphState.fromFixture] and
/// the property store accessors. Phase 2 will rebuild this through the
/// WAL applicator so the same fixture exercises the mutation path.
class SocialGraph {
  final GraphDb db;

  // Label ids
  final int personLabel;
  final int companyLabel;

  // Edge type ids
  final int knowsEdge;
  final int worksAtEdge;
  final int foundedEdge;

  // Property key ids
  final int nameKey;
  final int ageKey;
  final int titleKey;
  final int foundedYearKey;

  // Convenience handles
  final List<Vid> people;
  final List<Vid> companies;

  SocialGraph._({
    required this.db,
    required this.personLabel,
    required this.companyLabel,
    required this.knowsEdge,
    required this.worksAtEdge,
    required this.foundedEdge,
    required this.nameKey,
    required this.ageKey,
    required this.titleKey,
    required this.foundedYearKey,
    required this.people,
    required this.companies,
  });

  static const _personNames = [
    'Alice',
    'Bob',
    'Carol',
    'Dan',
    'Eve',
    'Frank',
    'Grace',
    'Heidi',
    'Ivan',
    'Judy',
    'Mallory',
    'Niaj',
  ];
  static const _personAges = [
    34, 41, 29, 52, 38, 47, 31, 27, 44, 36, 49, 33, //
  ];
  static const _personTitles = [
    'Engineer',
    'Director',
    'Designer',
    'CEO',
    'Engineer',
    'VP Sales',
    'Engineer',
    'Intern',
    'Marketing',
    'Engineer',
    'Operations',
    'Designer',
  ];
  static const _companyNames = ['Acme', 'Globex', 'Initech', 'Umbrella'];
  static const _companyFounded = [1947, 1989, 1997, 1968];

  // vid mapping: 0..11 people, 12..15 companies.
  static const _firstCompanyVid = 12;
  static const _totalNodes = 16;

  /// Edges as `(srcVid, dstVid, edgeTypeIndex)` where edgeTypeIndex
  /// matches the order knows=0, worksAt=1, founded=2.
  static const _edges = <List<int>>[
    // knows (within and across companies)
    [0, 2, 0], [0, 1, 0], [0, 6, 0],
    [1, 0, 0], [1, 3, 0], [1, 8, 0],
    [2, 0, 0], [2, 4, 0],
    [3, 1, 0], [3, 5, 0], [3, 7, 0],
    [4, 2, 0], [4, 0, 0],
    [5, 3, 0], [5, 10, 0],
    [6, 7, 0], [6, 9, 0], [6, 0, 0],
    [7, 6, 0], [7, 3, 0],
    [8, 1, 0], [8, 11, 0], [8, 10, 0],
    [9, 6, 0], [9, 7, 0],
    [10, 8, 0], [10, 5, 0],
    [11, 8, 0],
    // worksAt
    [0, 12, 1], [2, 12, 1], [4, 12, 1], // Acme
    [1, 13, 1], [3, 13, 1], [5, 13, 1], // Globex
    [6, 14, 1], [7, 14, 1], [9, 14, 1], // Initech
    [8, 15, 1], [10, 15, 1], [11, 15, 1], // Umbrella
    // founded
    [0, 12, 2], // Alice founded Acme
    [3, 13, 2], // Dan founded Globex
  ];

  /// Builds and populates a fresh in-memory graph.
  factory SocialGraph.build() {
    final n = _totalNodes;
    final edges = _edges;

    final srcs = Uint32List(edges.length);
    final dsts = Uint32List(edges.length);
    final edgeTypes = Uint32List(edges.length);
    for (var i = 0; i < edges.length; i++) {
      srcs[i] = edges[i][0];
      dsts[i] = edges[i][1];
      edgeTypes[i] = edges[i][2];
    }

    final labelOf = Uint32List(n);
    for (var v = 0; v < _firstCompanyVid; v++) {
      labelOf[v] = 0; // Person
    }
    for (var v = _firstCompanyVid; v < n; v++) {
      labelOf[v] = 1; // Company
    }

    final state = MutableGraphState.fromFixture(
      nodeCount: n,
      srcs: srcs,
      dsts: dsts,
      edgeTypes: edgeTypes,
      labelOf: labelOf,
      labelNames: const ['Person', 'Company'],
      edgeTypeNames: const ['knows', 'worksAt', 'founded'],
    );

    // Property keys (interned eagerly so the ids are known).
    final nameKey = state.strings.internPropKey('name');
    final ageKey = state.strings.internPropKey('age');
    final titleKey = state.strings.internPropKey('title');
    final foundedYearKey = state.strings.internPropKey('foundedYear');

    // People properties
    for (var i = 0; i < _personNames.length; i++) {
      state.nodeProps.setString(i, nameKey, _personNames[i]);
      state.nodeProps.setInt(i, ageKey, _personAges[i]);
      state.nodeProps.setString(i, titleKey, _personTitles[i]);
    }
    // Company properties
    for (var i = 0; i < _companyNames.length; i++) {
      final vid = _firstCompanyVid + i;
      state.nodeProps.setString(vid, nameKey, _companyNames[i]);
      state.nodeProps.setInt(vid, foundedYearKey, _companyFounded[i]);
    }

    final db = GraphDb.fromState(state);

    final people = List<Vid>.generate(
        _personNames.length, (i) => Vid(i),
        growable: false);
    final companies = List<Vid>.generate(
        _companyNames.length, (i) => Vid(_firstCompanyVid + i),
        growable: false);

    return SocialGraph._(
      db: db,
      personLabel: state.strings.internLabel('Person'),
      companyLabel: state.strings.internLabel('Company'),
      knowsEdge: state.strings.internEdgeType('knows'),
      worksAtEdge: state.strings.internEdgeType('worksAt'),
      foundedEdge: state.strings.internEdgeType('founded'),
      nameKey: nameKey,
      ageKey: ageKey,
      titleKey: titleKey,
      foundedYearKey: foundedYearKey,
      people: people,
      companies: companies,
    );
  }
}
