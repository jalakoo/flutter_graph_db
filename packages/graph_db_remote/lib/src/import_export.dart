/// Bulk import + export op shape.
///
/// `bulkImport` consumes a `Stream<ImportOp>` — adapters translate
/// these into backend-native bulk-load formats (CSV for Neo4j Admin
/// Import, GRAPH.BULK for FalkorDB, etc.). The schema is stable across
/// WAL versions; the sync engine adapts WAL entries to ImportOp
/// internally so adapters don't track WAL versioning.
library;

import 'package:graph_db_core/graph_db_core.dart';

sealed class ImportOp {
  const ImportOp();
}

class ImportNode extends ImportOp {
  final String logicalId;
  final List<String> labels;
  final Map<String, PropValue> properties;
  const ImportNode({
    required this.logicalId,
    required this.labels,
    required this.properties,
  });
}

class ImportEdge extends ImportOp {
  final String logicalId;
  final String srcLogicalId;
  final String dstLogicalId;
  final String type;
  final Map<String, PropValue> properties;
  const ImportEdge({
    required this.logicalId,
    required this.srcLogicalId,
    required this.dstLogicalId,
    required this.type,
    required this.properties,
  });
}

class ImportResult {
  final int nodesImported;
  final int edgesImported;
  final Duration elapsed;
  final List<String> warnings;
  const ImportResult({
    required this.nodesImported,
    required this.edgesImported,
    required this.elapsed,
    this.warnings = const [],
  });
}

/// Filter for `bulkExport` — adapter walks the backend and yields
/// matching `RemoteNode` / `RemoteEdge` instances.
class SubgraphSpec {
  /// `null` → all labels. Otherwise: emit only nodes carrying one of
  /// these labels (and edges incident on emitted nodes).
  final List<String>? nodeLabels;

  /// `null` → all edge types. Otherwise: only edges of these types.
  final List<String>? edgeTypes;

  /// Maximum rows to emit; `null` = unbounded.
  final int? limit;

  const SubgraphSpec({
    this.nodeLabels,
    this.edgeTypes,
    this.limit,
  });
}

/// Element yielded by `bulkExport` — either a node or an edge,
/// preserving streaming order. Discriminate via `is RemoteNode` /
/// `is RemoteEdge` on the consumer side.
typedef GraphElement = Object;
