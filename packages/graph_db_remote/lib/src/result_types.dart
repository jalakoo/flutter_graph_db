/// Remote result types.
///
/// The local engine (`graph_db_core`) and the remote adapters return
/// distinct concrete types (`LocalNode` vs `RemoteNode`) that share
/// abstract interfaces (`GraphNode` / `GraphEdge` / `GraphPath`). The
/// local/remote boundary is explicit in the type system so application
/// code doesn't accidentally pass a local handle into a remote API or
/// vice versa.
library;

import 'package:graph_db_core/graph_db_core.dart';

/// Common interface for any node — local or remote.
abstract interface class GraphNode {
  /// Stable across-backend identifier the engine uses for sync —
  /// UUIDv7 by default.
  String get logicalId;

  /// Single-label storage v1. Multi-label promotion is
  /// a future; for now the boundary returns one label.
  String? get label;

  Map<String, PropValue> get properties;
}

abstract interface class GraphEdge {
  String get logicalId;
  String get type;
  String get srcLogicalId;
  String get dstLogicalId;
  Map<String, PropValue> get properties;
}

abstract interface class GraphPath {
  List<GraphNode> get nodes;
  List<GraphEdge> get edges;
}

/// Result of a remote query — adapters convert backend rows into
/// `RemoteRow` shapes the application can iterate.
class RemoteRow {
  /// Keyed by column name (as returned by the backend's projection).
  final Map<String, Object?> values;
  const RemoteRow(this.values);

  Object? operator [](String name) => values[name];

  @override
  String toString() => 'RemoteRow($values)';
}

class RemoteQueryResult {
  final List<String> columns;
  final List<RemoteRow> rows;
  const RemoteQueryResult({required this.columns, required this.rows});

  int get length => rows.length;
  bool get isEmpty => rows.isEmpty;
}

class RemoteNode implements GraphNode {
  @override
  final String logicalId;
  @override
  final String? label;
  @override
  final Map<String, PropValue> properties;

  /// Backend-native id, if the backend exposes one (Neo4j's
  /// `node.elementId` / `id(n)` / FalkorDB's internal id). Used by
  /// the ID translation cache to map local logicalIds to
  /// backend ids without forcing the application to handle both.
  final String? remoteId;

  const RemoteNode({
    required this.logicalId,
    required this.label,
    required this.properties,
    this.remoteId,
  });
}

class RemoteEdge implements GraphEdge {
  @override
  final String logicalId;
  @override
  final String type;
  @override
  final String srcLogicalId;
  @override
  final String dstLogicalId;
  @override
  final Map<String, PropValue> properties;
  final String? remoteId;

  const RemoteEdge({
    required this.logicalId,
    required this.type,
    required this.srcLogicalId,
    required this.dstLogicalId,
    required this.properties,
    this.remoteId,
  });
}

class RemotePath implements GraphPath {
  @override
  final List<GraphNode> nodes;
  @override
  final List<GraphEdge> edges;
  const RemotePath({required this.nodes, required this.edges});
}
