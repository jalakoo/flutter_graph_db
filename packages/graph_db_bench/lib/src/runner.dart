import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:graph_db_core/graph_db_core.dart';

import 'gc_signal.dart';
import 'hub_seeds.dart';
import 'latency.dart';
import 'rmat.dart';

/// Reusable scratch space for the 2-hop BFS, so the BFS scaffolding
/// itself (visited set, frontier buffer) never allocates — only the read
/// primitive under test can. `epoch` is a generational marker: bump
/// [currentEpoch] per BFS instead of clearing the array.
class _BfsScratch {
  final Uint32List epoch;
  final Uint32List frontier;
  int currentEpoch = 0;

  _BfsScratch(int nodeCount)
      : epoch = Uint32List(nodeCount),
        frontier = Uint32List(nodeCount);
}

/// Runs all Phase-1 read workloads against `graph_db_core`'s real API
/// (`MutableGraphState` + `GraphDb`) on a fresh R-MAT fixture and
/// returns the full report as a string.
///
/// Mirrors `SPIKE_A/lib/runner.dart`'s output so numbers are directly
/// comparable to the spike record. [conn] supplies the JIT GC signal;
/// pass an unavailable [SelfConnection] (`SelfConnection(null, null)`)
/// for latency-only runs (AOT, device).
Future<String> runReadWorkloads({
  required bool quick,
  required SelfConnection conn,
  String envLabel = 'desktop',
}) async {
  final out = StringBuffer();

  final bigNodes = quick ? 1 << 16 : 1 << 20;
  final bigEdges = quick ? 100000 : 1000000;
  final bigLabels = (bigNodes ~/ 1024).clamp(2, 1 << 30);
  final bfsNodes = quick ? 1 << 12 : 1 << 14;
  final bfsEdges = quick ? 20000 : 100000;

  out.writeln('=== graph_db_bench — Phase 1 read workloads ===');
  out.writeln('env: $envLabel  |  ${quick ? 'quick' : 'full'} fixtures');
  out.writeln(conn.available
      ? 'gc signal: ON (vm-service connected)'
      : 'gc signal: off — latency only');

  final bigRmat = rmat(
    nodeCount: bigNodes,
    edgeCount: bigEdges,
    labelCount: bigLabels,
  );
  final big = buildFixture(bigRmat);
  final bfsRmat = rmat(
    nodeCount: bfsNodes,
    edgeCount: bfsEdges,
    labelCount: 16,
    seed: 0xbf5,
  );
  final bfs = buildFixture(bfsRmat);
  final bigDb = GraphDb.fromState(big);

  out.writeln('fixtures: big = $bigNodes nodes / $bigEdges edges / '
      '$bigLabels labels   bfs = $bfsNodes nodes / $bfsEdges edges');

  // --- Workload inputs -----------------------------------------------------
  final rng = Random(0xA110C0DE);
  // Hub seeds for neighbour traversal (Spike A finding — random seeds in
  // a sparse graph measure per-call overhead instead of per-element cost).
  final neighborSeeds =
      topOutDegreeVids(big.csr, quick ? 512 : 4096);
  final hubMaxDeg = big.csr.outDegree(neighborSeeds.first);
  final hubMinDeg = big.csr.outDegree(neighborSeeds.last);

  final bfsSeeds = Uint32List(256); // power of two -> cheap rotation
  for (var i = 0; i < bfsSeeds.length; i++) {
    bfsSeeds[i] = rng.nextInt(bfsNodes);
  }

  // Label closest to 1000 vids.
  var labelForScan = 0;
  var bestDelta = 1 << 62;
  big.csr.labelIndex.forEach((label, vids) {
    final d = (vids.length - 1000).abs();
    if (d < bestDelta) {
      bestDelta = d;
      labelForScan = label;
    }
  });
  final labelWidth = big.csr.labelIndex[labelForScan]!.length;

  // Property column on the big fixture — synthetic int values keyed by
  // `value`. Used for the predicate-scan workload.
  final valueKey = big.strings.internPropKey('value');
  for (var v = 0; v < bigNodes; v++) {
    big.nodeProps.setInt(v, valueKey, v * 31 + 7);
  }

  // ---- 1. Out-neighbour traversal ----------------------------------------
  out.writeln('\n--- out-neighbour traversal '
      '(fold over ${neighborSeeds.length} hub seeds / op; '
      'out-degree $hubMinDeg..$hubMaxDeg) ---');
  out.writeln(_header());

  // Shape A — `Iterable<({int dst, int eid})>` baseline (the shape plan
  // §5 explicitly rejects). Synthesised here only so the bench has a
  // concrete number for "what we'd be paying without the primitive layer".
  Iterable<({int dst, int eid})> iterableNeighbours(Csr csr, int vid) sync* {
    final end = csr.rowPtrOut[vid + 1];
    for (var i = csr.rowPtrOut[vid]; i < end; i++) {
      yield (dst: csr.colIdxOut[i], eid: csr.edgeIdOut[i]);
    }
  }

  int iterableNeighborFold() {
    var a = 0;
    for (var s = 0; s < neighborSeeds.length; s++) {
      for (final n in iterableNeighbours(big.csr, neighborSeeds[s])) {
        a ^= n.dst ^ n.eid;
      }
    }
    return a;
  }

  // Shape B — callback sugar via `GraphDb.forEachOutNeighbor` (plan §5).
  var cbAcc = 0;
  void cbVisit(Vid dst, Eid eid, int t) {
    cbAcc ^= dst.value ^ eid.value;
  }
  int callbackNeighborFold() {
    cbAcc = 0;
    for (var s = 0; s < neighborSeeds.length; s++) {
      bigDb.forEachOutNeighbor(Vid(neighborSeeds[s]), cbVisit);
    }
    return cbAcc;
  }

  // Shape C — primitive range API (plan §5: the v1 read shape).
  int primitiveNeighborFold() {
    var a = 0;
    final csr = big.csr;
    for (var s = 0; s < neighborSeeds.length; s++) {
      final vid = neighborSeeds[s];
      final end = csr.rowPtrOut[vid + 1];
      for (var i = csr.rowPtrOut[vid]; i < end; i++) {
        a ^= csr.colIdxOut[i] ^ csr.edgeIdOut[i];
      }
    }
    return a;
  }

  final neighbourReps = quick ? 200 : 400;
  for (final entry in <String, int Function()>{
    'iterable': iterableNeighborFold,
    'callback': callbackNeighborFold,
    'primitive': primitiveNeighborFold,
  }.entries) {
    final gc = await measureGcPerOp(conn, neighbourReps, entry.value);
    final lat = measureLatency(neighbourReps, entry.value);
    out.writeln(_row(entry.key, gc, lat, null));
  }

  // ---- 2. Label scan ------------------------------------------------------
  out.writeln('\n--- label scan (~$labelWidth vids / op)   '
      'target: p50 <= 10µs per ~1k vids ---');
  out.writeln(_header());

  int labelScanIterable() {
    var a = 0;
    for (final vid in big.csr.labelIndex[labelForScan]!) {
      a ^= vid;
    }
    return a;
  }

  int labelScanPrimitive() {
    var a = 0;
    final idx = bigDb.labelScan(labelForScan);
    for (var i = 0; i < idx.length; i++) {
      a ^= idx[i];
    }
    return a;
  }

  final labelTarget = 10.0 * labelWidth / 1000.0;
  for (final entry in <String, int Function()>{
    'iterable (for-in)': labelScanIterable,
    'primitive (indexed)': labelScanPrimitive,
  }.entries) {
    final gc = await measureGcPerOp(conn, 2000, entry.value);
    final lat = measureLatency(2000, entry.value);
    out.writeln(_row(entry.key, gc, lat, lat.p50 <= labelTarget));
  }

  // ---- 3. Two-hop BFS -----------------------------------------------------
  out.writeln('\n--- 2-hop BFS ($bfsEdges-edge graph)   '
      'target: p50 <= 100µs ---');
  out.writeln(_header());

  final scratch = _BfsScratch(bfs.csr.nodeCount);
  var ctr = 0;

  int bfsPrimitive() {
    scratch.currentEpoch++;
    final epoch = scratch.currentEpoch;
    final visited = scratch.epoch;
    final frontier = scratch.frontier;
    var acc = 0;
    final seed = bfsSeeds[ctr++ & 255];
    visited[seed] = epoch;
    var fLen = 0;
    final csr = bfs.csr;
    var end = csr.rowPtrOut[seed + 1];
    for (var i = csr.rowPtrOut[seed]; i < end; i++) {
      final d = csr.colIdxOut[i];
      if (visited[d] != epoch) {
        visited[d] = epoch;
        acc ^= d;
        frontier[fLen++] = d;
      }
    }
    final hop1 = fLen;
    for (var f = 0; f < hop1; f++) {
      final mid = frontier[f];
      end = csr.rowPtrOut[mid + 1];
      for (var i = csr.rowPtrOut[mid]; i < end; i++) {
        final d = csr.colIdxOut[i];
        if (visited[d] != epoch) {
          visited[d] = epoch;
          acc ^= d;
        }
      }
    }
    return acc;
  }

  final bfsReps = quick ? 3000 : 8000;
  final gcBfs = await measureGcPerOp(conn, bfsReps, bfsPrimitive);
  final latBfs = measureLatency(bfsReps, bfsPrimitive);
  out.writeln(_row('primitive', gcBfs, latBfs, latBfs.p50 <= 100.0));

  // ---- 4. Property predicate scan ----------------------------------------
  out.writeln('\n--- property predicate scan ($bigNodes nodes / op)   '
      'target: p50 <= 5ms ---');
  out.writeln(_header());

  int propRaw() {
    var a = 0;
    for (var v = 0; v < bigNodes; v++) {
      a ^= bigDb.getNodeIntProp(Vid(v), valueKey);
    }
    return a;
  }

  int propBoxed() {
    var a = 0;
    for (var v = 0; v < bigNodes; v++) {
      final pv = bigDb.getNodeProp(Vid(v), valueKey);
      escapeSink = pv;
      if (pv is PropInt) a ^= pv.value;
    }
    return a;
  }

  final propReps = quick ? 100 : 200;
  for (final entry in <String, int Function()>{
    'raw (getNodeIntProp)': propRaw,
    'boxed (getNodeProp)': propBoxed,
  }.entries) {
    final gc = await measureGcPerOp(conn, propReps, entry.value);
    final lat = measureLatency(quick ? 60 : 120, entry.value);
    out.writeln(_row(entry.key, gc, lat, lat.p50 <= 5000.0));
  }

  // ---- Notes --------------------------------------------------------------
  out.writeln('\nnotes:');
  out.writeln('  * gc/op = mean garbage collections triggered per op '
      '(needs the VM service; off on device + AOT).');
  out.writeln('  * The `primitive` shape is the locked Phase-1 read API '
      '(plan §5); `iterable` is benched only for comparison and is not '
      'offered by graph_db_core.');
  out.writeln('  * On device / AOT the GC signal is off; latency p99 '
      'spikes are the allocation proxy there.');
  return out.toString();
}

String _header() => '  ${'shape'.padRight(22)}'
    '${'gc/op'.padLeft(14)}'
    '${'p50 µs'.padLeft(12)}'
    '${'p99 µs'.padLeft(12)}'
    '${'min µs'.padLeft(12)}   target';

String _row(String name, double gc, LatencyStats lat, bool? pass) {
  final gcStr = gc.isNaN ? 'n/a' : gc.toStringAsFixed(3);
  final mark = pass == null ? '' : (pass ? 'PASS' : 'FAIL');
  return '  ${name.padRight(22)}'
      '${gcStr.padLeft(14)}'
      '${lat.p50.toStringAsFixed(2).padLeft(12)}'
      '${lat.p99.toStringAsFixed(2).padLeft(12)}'
      '${lat.min.toStringAsFixed(2).padLeft(12)}   $mark';
}
