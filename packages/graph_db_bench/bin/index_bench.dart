import 'dart:io';

import 'package:graph_db_bench/graph_db_bench.dart';

/// Phase-5 indexed-update bench entry point.
///
/// Usage:
///   dart run bin/index_bench.dart [--quick]
Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final r = await runIndexWorkloads(quick: quick);
  stdout.write(r.format(
    envLabel: 'desktop (${Platform.version.split(' ').first})',
  ));
}
