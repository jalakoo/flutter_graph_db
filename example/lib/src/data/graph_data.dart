import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'engine_view.dart';

/// JSON-serialisable description of a graph — the source of truth the
/// example's repository writes to disk and rebuilds the engine state
/// from on every mutation.
///
/// This stand-in for the eventual `graph_db_wal` (CBOR + WAL framing)
/// is kept inside the example deliberately. Production persistence
/// lives in its own package.
class GraphData {
  static const int currentVersion = 1;

  /// Catalog — frozen at fixture creation. Mutations only touch [nodes]
  /// and [edges].
  final List<String> labelNames;
  final List<String> edgeTypeNames;
  final List<String> propKeyNames;

  /// Indexed by vid. Tombstoned entries set `deleted = true` — they keep
  /// their slot so previously-issued [Vid] handles never silently
  /// rebind.
  final List<NodeRecord> nodes;

  /// Indexed by eid. Same tombstone discipline as [nodes].
  final List<EdgeRecord> edges;

  GraphData({
    required this.labelNames,
    required this.edgeTypeNames,
    required this.propKeyNames,
    required this.nodes,
    required this.edges,
  });

  Map<String, dynamic> toJson() => {
        'v': currentVersion,
        'labels': labelNames,
        'edgeTypes': edgeTypeNames,
        'propKeys': propKeyNames,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
      };

  factory GraphData.fromJson(Map<String, dynamic> json) {
    final version = json['v'] as int? ?? 0;
    if (version != currentVersion) {
      throw FormatException(
          'unsupported graph data version $version (expected $currentVersion)');
    }
    return GraphData(
      labelNames: List<String>.from(json['labels'] as List),
      edgeTypeNames: List<String>.from(json['edgeTypes'] as List),
      propKeyNames: List<String>.from(json['propKeys'] as List),
      nodes: [
        for (final n in json['nodes'] as List)
          NodeRecord.fromJson(n as Map<String, dynamic>)
      ],
      edges: [
        for (final e in json['edges'] as List)
          EdgeRecord.fromJson(e as Map<String, dynamic>)
      ],
    );
  }

  GraphData copy() => GraphData(
        labelNames: List.of(labelNames),
        edgeTypeNames: List.of(edgeTypeNames),
        propKeyNames: List.of(propKeyNames),
        nodes: [for (final n in nodes) n.copy()],
        edges: [for (final e in edges) e.copy()],
      );

  /// Builds a fresh [EngineView] (engine state + canonical handle ids)
  /// from this data. Called on every repository commit.
  EngineView buildEngineView() {
    final activeEdges = <int>[];
    for (var i = 0; i < edges.length; i++) {
      if (!edges[i].deleted) activeEdges.add(i);
    }
    final n = nodes.length;
    final eCount = activeEdges.length;
    final srcs = Uint32List(eCount);
    final dsts = Uint32List(eCount);
    final edgeTypes = Uint32List(eCount);
    final eids = Uint32List(eCount);
    for (var i = 0; i < eCount; i++) {
      final origIdx = activeEdges[i];
      final rec = edges[origIdx];
      srcs[i] = rec.src;
      dsts[i] = rec.dst;
      edgeTypes[i] = rec.typeId;
      eids[i] = origIdx;
    }
    final labelOf = Uint32List(n);
    final tombstones = Uint8List(n);
    for (var v = 0; v < n; v++) {
      labelOf[v] = nodes[v].labelId;
      if (nodes[v].deleted) tombstones[v] = 1;
    }

    // Pre-size the property store with headroom so mutation adds don't
    // need to grow `vidToSlot` arrays.
    final vidSpace = n + 64;
    final eidSpace = edges.length + 64;

    final state = MutableGraphState.fromFixture(
      nodeCount: n,
      srcs: srcs,
      dsts: dsts,
      edgeTypes: edgeTypes,
      labelOf: labelOf,
      labelNames: labelNames,
      edgeTypeNames: edgeTypeNames,
      eids: eids,
      nodeTombstones: tombstones,
      vidSpace: vidSpace,
      eidSpace: eidSpace,
    );

    // Intern the property keys eagerly, in the order they're listed in
    // the catalog. The repository hands back the (cached) ids via the
    // returned [SocialGraph], so screens never need to re-intern.
    final propKeyId = <String, int>{};
    for (final k in propKeyNames) {
      propKeyId[k] = state.strings.internPropKey(k);
    }

    // Apply node properties.
    for (var v = 0; v < n; v++) {
      if (nodes[v].deleted) continue;
      for (final entry in nodes[v].props.entries) {
        _setProp(state.nodeProps, v, propKeyId[entry.key]!, entry.value);
      }
    }
    // Apply edge properties.
    for (final origIdx in activeEdges) {
      final rec = edges[origIdx];
      for (final entry in rec.props.entries) {
        _setProp(state.edgeProps, origIdx, propKeyId[entry.key]!, entry.value);
      }
    }

    return EngineView.from(
      db: GraphDb.fromState(state),
      labelNames: labelNames,
      edgeTypeNames: edgeTypeNames,
      propKeyNames: propKeyNames,
    );
  }

  static void _setProp(
      PropertyStore store, int vid, int keyId, Object? value) {
    switch (value) {
      case null:
        store.createColumn(keyId, store.columnType(keyId) ?? ColumnType.int_);
        store.setNull(vid, keyId);
      case final int v:
        store.setInt(vid, keyId, v);
      case final double v:
        store.setDouble(vid, keyId, v);
      case final bool v:
        store.setBool(vid, keyId, v);
      case final String v:
        store.setString(vid, keyId, v);
      default:
        throw ArgumentError(
            'unsupported property value type ${value.runtimeType}: $value');
    }
  }

  /// The hand-built social-graph fixture used by the example's reset
  /// action and on first launch.
  static GraphData socialFixture() {
    const labelNames = ['Person', 'Company'];
    const edgeTypeNames = ['knows', 'worksAt', 'founded'];
    const propKeyNames = ['name', 'age', 'title', 'foundedYear'];

    const personNames = [
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
    const personAges = [34, 41, 29, 52, 38, 47, 31, 27, 44, 36, 49, 33];
    const personTitles = [
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
    const companyNames = ['Acme', 'Globex', 'Initech', 'Umbrella'];
    const companyFounded = [1947, 1989, 1997, 1968];

    final nodes = <NodeRecord>[
      for (var i = 0; i < personNames.length; i++)
        NodeRecord(labelId: 0, props: {
          'name': personNames[i],
          'age': personAges[i],
          'title': personTitles[i],
        }),
      for (var i = 0; i < companyNames.length; i++)
        NodeRecord(labelId: 1, props: {
          'name': companyNames[i],
          'foundedYear': companyFounded[i],
        }),
    ];

    // (src, dst, edgeType)
    const edgeSpec = <List<int>>[
      // knows
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
      [0, 12, 1], [2, 12, 1], [4, 12, 1],
      [1, 13, 1], [3, 13, 1], [5, 13, 1],
      [6, 14, 1], [7, 14, 1], [9, 14, 1],
      [8, 15, 1], [10, 15, 1], [11, 15, 1],
      // founded
      [0, 12, 2],
      [3, 13, 2],
    ];
    final edges = <EdgeRecord>[
      for (final e in edgeSpec)
        EdgeRecord(src: e[0], dst: e[1], typeId: e[2], props: {})
    ];

    return GraphData(
      labelNames: List.of(labelNames),
      edgeTypeNames: List.of(edgeTypeNames),
      propKeyNames: List.of(propKeyNames),
      nodes: nodes,
      edges: edges,
    );
  }
}

class NodeRecord {
  bool deleted;
  int labelId;
  Map<String, Object?> props;

  NodeRecord({
    this.deleted = false,
    required this.labelId,
    required this.props,
  });

  Map<String, dynamic> toJson() => {
        if (deleted) 'deleted': true,
        'label': labelId,
        'props': props,
      };

  factory NodeRecord.fromJson(Map<String, dynamic> j) => NodeRecord(
        deleted: j['deleted'] as bool? ?? false,
        labelId: j['label'] as int,
        props: Map<String, Object?>.from(j['props'] as Map),
      );

  NodeRecord copy() => NodeRecord(
        deleted: deleted,
        labelId: labelId,
        props: Map<String, Object?>.from(props),
      );
}

class EdgeRecord {
  bool deleted;
  int src;
  int dst;
  int typeId;
  Map<String, Object?> props;

  EdgeRecord({
    this.deleted = false,
    required this.src,
    required this.dst,
    required this.typeId,
    required this.props,
  });

  Map<String, dynamic> toJson() => {
        if (deleted) 'deleted': true,
        'src': src,
        'dst': dst,
        'type': typeId,
        'props': props,
      };

  factory EdgeRecord.fromJson(Map<String, dynamic> j) => EdgeRecord(
        deleted: j['deleted'] as bool? ?? false,
        src: j['src'] as int,
        dst: j['dst'] as int,
        typeId: j['type'] as int,
        props: Map<String, Object?>.from(j['props'] as Map),
      );

  EdgeRecord copy() => EdgeRecord(
        deleted: deleted,
        src: src,
        dst: dst,
        typeId: typeId,
        props: Map<String, Object?>.from(props),
      );
}
