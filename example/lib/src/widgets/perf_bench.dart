/// In-app perf bench. Runs a sequence of mutations
/// + reads against a *temporary* `GraphDb` (the demo graph is left
/// untouched) and reports total / p50 / p99 / throughput so the user
/// can capture numbers from a real browser / iOS / Android session
/// without leaving the app.
///
/// Why a temp DB instead of the live demo: keeps the bench
/// self-contained (no cleanup, no WAL writes) and makes runs
/// repeatable — the first run pays the same setup cost as the tenth.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:graph_db_core/graph_db_core.dart';

class PerfBench extends StatefulWidget {
  const PerfBench({super.key});

  @override
  State<PerfBench> createState() => _PerfBenchState();
}

class _PerfBenchState extends State<PerfBench> {
  int _n = 1000;
  bool _running = false;
  _BenchResult? _result;
  Object? _error;

  static const _sizes = [100, 1000, 10000, 100000];

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      // Run off the build phase — yield once so the spinner paints.
      await Future<void>.delayed(Duration.zero);
      final result = await _runBench(_n);
      if (!mounted) return;
      setState(() {
        _result = result;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.speed, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  'Perf bench',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Insert N nodes into a fresh in-memory GraphDb, then '
              'measure read latency + merge stall. Numbers reflect '
              'this device / browser.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('N: ', style: theme.textTheme.labelLarge),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _n,
                  items: [
                    for (final s in _sizes)
                      DropdownMenuItem(value: s, child: Text(_fmtThousands(s))),
                  ],
                  onChanged: _running
                      ? null
                      : (v) {
                          if (v != null) setState(() => _n = v);
                        },
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _running ? null : _run,
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(_running ? 'Running…' : 'Run'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                'Error: $_error',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_result != null) ...[
              const SizedBox(height: 16),
              _ResultsTable(result: _result!),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultsTable extends StatefulWidget {
  final _BenchResult result;
  const _ResultsTable({required this.result});

  @override
  State<_ResultsTable> createState() => _ResultsTableState();
}

class _ResultsTableState extends State<_ResultsTable> {
  bool _copied = false;
  Timer? _copyResetTimer;

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.result.shareText));
    if (!mounted) return;
    setState(() => _copied = true);
    _copyResetTimer?.cancel();
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final result = widget.result;

    Widget row(String phase, _Stats s, String unit) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 110,
              child: SelectableText(phase, style: theme.textTheme.labelLarge),
            ),
            Expanded(
              child: SelectableText(
                'total ${_fmt(s.totalUs)}µs  '
                'p50 ${_fmt(s.p50Us)}$unit  '
                'p99 ${_fmt(s.p99Us)}$unit  '
                '${_fmt(s.opsPerSec.round())}/s',
                style: mono,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(color: theme.colorScheme.outlineVariant),
        const SizedBox(height: 8),
        row('Insert', result.insert, 'µs'),
        row('Read', result.read, 'µs'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: SelectableText('Merge', style: theme.textTheme.labelLarge),
              ),
              Expanded(
                child: SelectableText(
                  '${_fmt(result.mergeUs)}µs (sync, full overlay fold)',
                  style: mono,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Copyable summary block — long-press selects on touch, mouse
        // selects on drag; the button copies the canonical share line
        // straight to the clipboard with no selection ceremony.
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  result.shareText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: _copied ? 'Copied' : 'Copy to clipboard',
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
                color: _copied ? theme.colorScheme.primary : null,
                visualDensity: VisualDensity.compact,
                onPressed: _copy,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(int n) => _fmtThousands(n);
}

/// Thousands-separated integer for display ("1,000,000"). Used in the
/// N dropdown and the results table.
String _fmtThousands(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

class _Stats {
  final int totalUs;
  final int p50Us;
  final int p99Us;
  final double opsPerSec;
  const _Stats(this.totalUs, this.p50Us, this.p99Us, this.opsPerSec);
}

class _BenchResult {
  final int n;
  final _Stats insert;
  final _Stats read;
  final int mergeUs;
  const _BenchResult({
    required this.n,
    required this.insert,
    required this.read,
    required this.mergeUs,
  });

  /// Single-line summary suitable for pasting into a chat / issue.
  String get shareText {
    final platform = defaultTargetPlatform.name; // iOS / android / macOS / …
    final web = kIsWeb ? '/web' : '';
    return 'flutter_graph_db perf bench  [$platform$web]  '
        'N=$n  '
        'insert p50=${insert.p50Us}µs p99=${insert.p99Us}µs '
        '(${insert.opsPerSec.round()}/s)  '
        'read p50=${read.p50Us}µs p99=${read.p99Us}µs  '
        'merge=$mergeUsµs';
  }
}

Future<_BenchResult> _runBench(int n) async {
  // Fresh temp engine — no WAL, no live demo pollution.
  final db = GraphDb.fromState(
    MutableGraphState.fromFixture(
      nodeCount: 0,
      srcs: Uint32List(0),
      dsts: Uint32List(0),
      edgeTypes: Uint32List(0),
      labelOf: Uint32List(0),
      labelNames: const [],
      edgeTypeNames: const [],
      // Pre-size to N so overlay-promotion doesn't dominate the run.
      vidSpace: n.clamp(64, 1 << 24),
      eidSpace: n.clamp(64, 1 << 24),
    ),
  );
  final personLabel = db.internLabel('BenchPerson');
  final nameKey = db.internPropKey('name');

  // ---- Insert phase ----
  final insertLatencies = List<int>.filled(n, 0);
  final sw = Stopwatch();
  final overallSw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    sw
      ..reset()
      ..start();
    await db.runTransaction((txn) {
      txn.addNode(
        labelIds: [personLabel],
        props: {nameKey: PropString('node-$i')},
      );
    });
    sw.stop();
    insertLatencies[i] = sw.elapsedMicroseconds;
  }
  final insertTotalUs = overallSw.elapsedMicroseconds;

  // ---- Merge phase ----
  // Run BEFORE the read phase. Inserts land in the overlay; primitive
  // reads (outDegree) hit the CSR, which is empty until the overlay
  // folds in. Measuring merge here also captures the cost the engine
  // would have paid asynchronously at the threshold.
  sw
    ..reset()
    ..start();
  db.state.mergeNow();
  sw.stop();
  final mergeUs = sw.elapsedMicroseconds;

  // ---- Read phase ----
  // 10× the node count, capped, so we get a clean p99 even at N=100.
  final readCount = (n * 10).clamp(1000, 100000);
  final readLatencies = List<int>.filled(readCount, 0);
  overallSw
    ..reset()
    ..start();
  // Deterministic walk so reads aren't dominated by RNG cost.
  for (var i = 0; i < readCount; i++) {
    final vid = Vid(i % n);
    sw
      ..reset()
      ..start();
    final _ = db.outDegree(vid);
    sw.stop();
    readLatencies[i] = sw.elapsedMicroseconds;
  }
  final readTotalUs = overallSw.elapsedMicroseconds;

  return _BenchResult(
    n: n,
    insert: _statsOf(insertLatencies, insertTotalUs),
    read: _statsOf(readLatencies, readTotalUs),
    mergeUs: mergeUs,
  );
}

_Stats _statsOf(List<int> latencies, int totalUs) {
  latencies.sort();
  final p50 = latencies[latencies.length ~/ 2];
  final p99 = latencies[(latencies.length * 99 ~/ 100).clamp(
    0,
    latencies.length - 1,
  )];
  final opsPerSec = totalUs == 0 ? 0.0 : latencies.length * 1e6 / totalUs;
  return _Stats(totalUs, p50, p99, opsPerSec);
}
