import 'dart:io';

import 'package:graph_db_bench/graph_db_bench.dart';

/// Phase-1 read benchmark entry point.
///
/// Usage:
///   dart run --enable-vm-service bin/read_bench.dart [--quick]
///     -> latency + GC signal (gc/op needs the VM service)
///   dart compile exe bin/read_bench.dart -o build/bench && ./build/bench
///     -> AOT latency only (closer to device; gc/op shows n/a)
///
/// On-device runs go through `device_runner/integration_test/`.
Future<void> main(List<String> args) async {
  final quick = args.contains('--quick');
  final conn = await connectSelf();

  final envLabel = conn.available
      ? 'desktop-JIT (${Platform.version.split(' ').first})'
      : 'desktop-AOT (${Platform.version.split(' ').first})';

  final report = await runReadWorkloads(
    quick: quick,
    conn: conn,
    envLabel: envLabel,
  );
  stdout.write(report);

  if (conn.service != null) {
    await conn.service!.dispose();
  }
  if (blackhole == 0x7fffffffffffffff) {
    stderr.writeln(blackhole);
  }
  exit(0);
}
