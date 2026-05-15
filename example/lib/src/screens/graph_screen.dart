import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';
import 'package:graphview/GraphView.dart';

import '../data/engine_view.dart';
import '../db_scope.dart';
import '../graph_layout/non_overlap_algorithm.dart';
import 'company_detail_screen.dart';
import 'person_detail_screen.dart';

/// Interactive node-link view of the whole graph. Force-directed layout
/// via `graphview`. Nodes are coloured by label, edges by type. Tap a
/// Person to drill into [PersonDetailScreen]; tap a Company to surface
/// a quick summary chip.
class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  Graph? _graph;
  EngineView? _view;
  late FruchtermanReingoldAlgorithm _algorithm;

  @override
  void initState() {
    super.initState();
    // Use the non-overlap subclass: force-directed positioning *then*
    // a deterministic AABB-separation pass. Guarantees no two node
    // rects overlap in the final layout — see
    // graph_layout/non_overlap_algorithm.dart.
    _algorithm = NonOverlapFruchtermanReingoldAlgorithm(
      FruchtermanReingoldConfiguration(
        iterations: 1000,
        clusterPadding: 24,
      ),
      padding: 24,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rebuild the visual graph whenever the repository commits a
    // mutation — `EngineView` instances are fresh per commit, so a
    // reference check is enough to skip no-op rebuilds.
    final view = DbScope.of(context);
    if (identical(view, _view) && _graph != null) return;
    _view = view;
    _graph = _buildGraph(view, context);
  }

  Graph _buildGraph(EngineView sg, BuildContext context) {
    final db = sg.db;
    final scheme = Theme.of(context).colorScheme;
    final g = Graph()..isTree = false;

    final nodes = <int, Node>{};
    for (var v = 0; v < db.nodeCount; v++) {
      final node = Node.Id(v);
      nodes[v] = node;
      g.addNode(node);
    }

    // Avoid duplicating bidirectional edges visually — graphview will
    // render every Edge object so reverse-CSR scans would double-draw.
    // The forward scan is enough; reverse traversals still work in
    // the data layer.
    for (var v = 0; v < db.nodeCount; v++) {
      db.forEachOutNeighbor(Vid(v), (dst, eid, t) {
        g.addEdge(
          nodes[v]!,
          nodes[dst.value]!,
          paint: Paint()
            ..color = _edgeColor(t, sg, scheme).withValues(alpha: 0.6)
            ..strokeWidth = 1.4
            ..style = PaintingStyle.stroke,
        );
      });
    }
    return g;
  }

  Color _edgeColor(int type, EngineView sg, ColorScheme scheme) {
    if (type == sg.knowsEdge) return scheme.primary;
    if (type == sg.worksAtEdge) return scheme.tertiary;
    if (type == sg.foundedEdge) return scheme.error;
    return scheme.outline;
  }

  @override
  Widget build(BuildContext context) {
    final graph = _graph;
    final sg = _view;
    if (graph == null || sg == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Graph'),
        scrolledUnderElevation: 1,
      ),
      body: Column(
        children: [
          _Legend(sg: sg),
          const Divider(height: 1),
          Expanded(
            child: InteractiveViewer(
              constrained: false,
              boundaryMargin: const EdgeInsets.all(200),
              minScale: 0.3,
              maxScale: 3.0,
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: GraphView(
                  graph: graph,
                  algorithm: _algorithm,
                  builder: (node) {
                    final vid = Vid(node.key!.value as int);
                    return _NodeWidget(vid: vid, sg: sg);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One node rendered as either a Person avatar or a Company chip.
class _NodeWidget extends StatelessWidget {
  final Vid vid;
  final EngineView sg;
  const _NodeWidget({required this.vid, required this.sg});

  @override
  Widget build(BuildContext context) {
    final db = sg.db;
    final scheme = Theme.of(context).colorScheme;
    final isPerson = db.labelOf(vid) == sg.personLabel;
    final name = db.getNodeStringProp(vid, sg.nameKey);

    if (isPerson) {
      return _NodeButton(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => PersonDetailScreen(vid: vid)),
          );
        },
        child: Tooltip(
          message: name,
          child: CircleAvatar(
            radius: 22,
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
            child: Text(name.characters.first,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      );
    }

    // Company
    return _NodeButton(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => CompanyDetailScreen(vid: vid)),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.tertiary, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.apartment, size: 16, color: scheme.onTertiaryContainer),
            const SizedBox(width: 6),
            Text(
              name,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NodeButton extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;
  const _NodeButton({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: child,
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final EngineView sg;
  const _Legend({required this.sg});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _Swatch(color: scheme.primaryContainer, label: 'Person'),
            const SizedBox(width: 12),
            _Swatch(color: scheme.tertiaryContainer, label: 'Company'),
            const SizedBox(width: 18),
            _EdgeSwatch(color: scheme.primary, label: 'knows'),
            const SizedBox(width: 12),
            _EdgeSwatch(color: scheme.tertiary, label: 'worksAt'),
            const SizedBox(width: 12),
            _EdgeSwatch(color: scheme.error, label: 'founded'),
            const SizedBox(width: 18),
            Text('drag · pinch to zoom',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final String label;
  const _Swatch({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _EdgeSwatch extends StatelessWidget {
  final Color color;
  final String label;
  const _EdgeSwatch({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 18, height: 2, color: color),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
