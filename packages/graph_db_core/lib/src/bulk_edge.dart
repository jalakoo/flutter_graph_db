/// Input to `GraphDb.bulkAddEdges` (plan §14 Phase 2F).
library;

import 'ids.dart';

/// One edge to insert via the bulk path. Endpoints must already
/// exist; properties are not supported on the bulk path (see
/// `runTransaction` for property-carrying edges).
class BulkEdge {
  final Vid src;
  final Vid dst;
  final int typeId;
  final String? logicalId;

  const BulkEdge({
    required this.src,
    required this.dst,
    required this.typeId,
    this.logicalId,
  });
}
