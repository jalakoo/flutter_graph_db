import 'dart:io';

import 'package:graph_db_bench/graph_db_bench.dart';
import 'package:graph_db_core/graph_db_core.dart';

/// Phase-2 write benchmark entry point.
///
/// Usage:
///   dart run bin/write_bench.dart [--quick] [--worker]
///
/// Measures bulkAddEdges wall time, single-txn commit p99, and the
/// overlay-merge stall p99 against plan §15 targets. With `--worker`,
/// the merge runs in a worker isolate (plan §2.3 / Phase 2 polish).
Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final useWorker = args.contains('--worker');
  final coord = useWorker ? await MergeCoordinator.spawn() : null;
  final report = await runWriteWorkloads(quick: quick, coord: coord);
  stdout.write(report.format(
    envLabel: 'desktop (${Platform.version.split(' ').first})'
        '${useWorker ? ' + worker merge' : ''}',
  ));
  await coord?.dispose();
}
