/// Flutter-native graph database — umbrella package.
///
/// Re-exports the three production packages so Flutter app developers
/// can depend on a single package + import a single file. For
/// tree-shaking or library authoring, depend on the sub-packages
/// directly instead — see this package's README.
library;

export 'package:graph_db_core/graph_db_core.dart';
export 'package:graph_db_gql/graph_db_gql.dart';
export 'package:graph_db_wal/graph_db_wal.dart';
