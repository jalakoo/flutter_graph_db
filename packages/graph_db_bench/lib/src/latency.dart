import 'dart:typed_data';

/// Data-dependent sink. Folded results are XORed in here so the AOT/JIT
/// optimiser cannot prove the benchmarked work is dead and delete it.
/// Public so on-device runners can also XOR into it.
int blackhole = 0;

/// Reference sink for heap objects — assigning a freshly boxed value here
/// makes it *escape*, defeating the VM's escape analysis / scalar
/// replacement (a box that is allocated and immediately discarded would
/// otherwise read as zero allocation; this came up real in).
Object? escapeSink;

class LatencyStats {
  final double p50;
  final double p99;
  final double min;
  final int samples;
  const LatencyStats({
    required this.p50,
    required this.p99,
    required this.min,
    required this.samples,
  });
}

/// Runs [op] [samples] times and returns p50 / p99 / min latency in µs.
///
/// Uses `Stopwatch.elapsedTicks` (sub-µs resolution on every platform)
/// rather than `elapsedMicroseconds`, which is too coarse for the
/// ~10µs label-scan target.
LatencyStats measureLatency(int samples, int Function() op) {
  var sink = 0;
  final warm = (samples >> 2) + 32;
  for (var i = 0; i < warm; i++) {
    sink ^= op();
  }
  final t = Float64List(samples);
  final sw = Stopwatch();
  for (var i = 0; i < samples; i++) {
    sw
      ..reset()
      ..start();
    sink ^= op();
    sw.stop();
    t[i] = sw.elapsedTicks * 1e6 / sw.frequency;
  }
  blackhole ^= sink;
  t.sort();
  int q(double p) => (samples * p).floor().clamp(0, samples - 1);
  return LatencyStats(
    p50: t[q(0.50)],
    p99: t[q(0.99)],
    min: t[0],
    samples: samples,
  );
}
