import 'package:graph_db_core/graph_db_core.dart';

/// A typed read view over the example's social graph — a [GraphDb]
/// plus the cached, structurally-stable handle ids the screens use.
///
/// The repository rebuilds this on every commit (mutations rebuild the
/// engine state from `GraphData`); widgets receive a fresh [EngineView]
/// via [DbScope] and re-read.
class EngineView {
  final GraphDb db;

  // Catalog names — same order as in the underlying [GraphData].
  final List<String> labelNames;
  final List<String> edgeTypeNames;
  final List<String> propKeyNames;

  // Canonical handle ids — resolved on construction.
  final int personLabel;
  final int companyLabel;
  final int knowsEdge;
  final int worksAtEdge;
  final int foundedEdge;
  final int nameKey;
  final int ageKey;
  final int titleKey;
  final int foundedYearKey;

  /// All non-deleted Person / Company vids. `labelScan` already filters
  /// tombstoned nodes, so these lists track current state.
  final List<Vid> people;
  final List<Vid> companies;

  EngineView._({
    required this.db,
    required this.labelNames,
    required this.edgeTypeNames,
    required this.propKeyNames,
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

  factory EngineView.from({
    required GraphDb db,
    required List<String> labelNames,
    required List<String> edgeTypeNames,
    required List<String> propKeyNames,
  }) {
    // One schema declaration replaces the per-name intern calls and
    // reserves the typed columns up front. Types match what the loader
    // writes (see `GraphData._setProp`): name/title are String, age and
    // foundedYear are int — so these declarations no-op against the
    // already-locked columns.
    final schema = db.defineSchema(
      labels: {'Person', 'Company'},
      edgeTypes: {'knows', 'worksAt', 'founded'},
      propKeys: {
        'name': ColumnType.string,
        'age': ColumnType.int_,
        'title': ColumnType.string,
        'foundedYear': ColumnType.int_,
      },
    );

    final personLabel = schema.label('Person');
    final companyLabel = schema.label('Company');

    final people = [
      for (final raw in db.labelScan(personLabel)) Vid(raw),
    ];
    final companies = [
      for (final raw in db.labelScan(companyLabel)) Vid(raw),
    ];

    return EngineView._(
      db: db,
      labelNames: labelNames,
      edgeTypeNames: edgeTypeNames,
      propKeyNames: propKeyNames,
      personLabel: personLabel,
      companyLabel: companyLabel,
      knowsEdge: schema.edgeType('knows'),
      worksAtEdge: schema.edgeType('worksAt'),
      foundedEdge: schema.edgeType('founded'),
      nameKey: schema.propKey('name'),
      ageKey: schema.propKey('age'),
      titleKey: schema.propKey('title'),
      foundedYearKey: schema.propKey('foundedYear'),
      people: people,
      companies: companies,
    );
  }
}
