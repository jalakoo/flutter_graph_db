import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import '../widgets/perf_bench.dart';

/// Whole-graph stats. Demonstrates the cheap, allocation-free range
/// primitives summed across the full vid space.
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sg = DbScope.of(context);
    final db = sg.db;
    final theme = Theme.of(context);

    // Compute aggregate stats inline — the whole graph is tiny here, so
    // these are sub-microsecond reads.
    var totalOut = 0;
    var maxOut = 0;
    var hubVid = const Vid(0);
    for (var raw = 0; raw < db.nodeCount; raw++) {
      final d = db.outDegree(Vid(raw));
      totalOut += d;
      if (d > maxOut) {
        maxOut = d;
        hubVid = Vid(raw);
      }
    }
    final hubName = db.getNodeStringProp(hubVid, sg.nameKey);
    final avgOut = (totalOut / db.nodeCount).toStringAsFixed(2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stats'),
        scrolledUnderElevation: 1,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatTile(
            label: 'Nodes',
            value: '${db.nodeCount}',
            icon: Icons.scatter_plot,
          ),
          _StatTile(
            label: 'Edges',
            value: '${db.edgeCount}',
            icon: Icons.timeline,
          ),
          _StatTile(
            label: 'People',
            value: '${db.labelScan(sg.personLabel).length}',
            icon: Icons.people,
          ),
          _StatTile(
            label: 'Companies',
            value: '${db.labelScan(sg.companyLabel).length}',
            icon: Icons.apartment,
          ),
          _StatTile(
            label: 'Average out-degree',
            value: avgOut,
            icon: Icons.functions,
          ),
          _StatTile(
            label: 'Hub node (max out-degree)',
            value: '$hubName · $maxOut',
            icon: Icons.hub,
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'Reads use the primitive range API — '
              'allocation-free. Stats here scan the whole '
              '${db.nodeCount}-node graph in <1ms on desktop / iPhone.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const PerfBench(),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
