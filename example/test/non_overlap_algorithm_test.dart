import 'package:flutter/painting.dart';
import 'package:flutter_graph_db_example/src/graph_layout/non_overlap_algorithm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphview/GraphView.dart';

void main() {
  group('NonOverlapFruchtermanReingoldAlgorithm', () {
    test('separates every overlapping pair after layout', () {
      // 16-node dense graph (clique-ish) — worst-case for force-directed
      // overlap. Mirrors the example's social-graph fixture size.
      final graph = Graph()..isTree = false;
      final nodes = <Node>[];
      for (var i = 0; i < 16; i++) {
        final n = Node.Id(i);
        n.size = const Size(60, 60);
        graph.addNode(n);
        nodes.add(n);
      }
      // Heavy edges so attraction pulls nodes towards each other.
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j += 2) {
          graph.addEdge(nodes[i], nodes[j]);
        }
      }

      final algo = NonOverlapFruchtermanReingoldAlgorithm(
        FruchtermanReingoldConfiguration(iterations: 500),
        padding: 12,
      );
      algo.run(graph, 0, 0);

      // No two AABBs (with padding) may overlap.
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          final a = nodes[i];
          final b = nodes[j];
          final cx = (a.x + a.width / 2) - (b.x + b.width / 2);
          final cy = (a.y + a.height / 2) - (b.y + b.height / 2);
          final minDx = (a.width + b.width) / 2 + 12;
          final minDy = (a.height + b.height) / 2 + 12;
          final overlapping = cx.abs() < minDx && cy.abs() < minDy;
          expect(
            overlapping,
            isFalse,
            reason: 'nodes $i and $j overlap '
                'at (${a.x.toStringAsFixed(1)}, ${a.y.toStringAsFixed(1)}) '
                'and (${b.x.toStringAsFixed(1)}, ${b.y.toStringAsFixed(1)})',
          );
        }
      }
    });

    test('handles coincident starting positions deterministically', () {
      // Three nodes initially placed exactly on top of each other —
      // tests the centre-coincident branch of the MTV resolver.
      final graph = Graph()..isTree = false;
      final nodes = <Node>[];
      for (var i = 0; i < 3; i++) {
        final n = Node.Id(i)
          ..size = const Size(40, 40)
          ..position = Offset.zero;
        graph.addNode(n);
        nodes.add(n);
      }
      // No edges → only repulsion + the separation pass.
      final algo = NonOverlapFruchtermanReingoldAlgorithm(
        FruchtermanReingoldConfiguration(
            iterations: 200, shuffleNodes: false),
        padding: 8,
      );
      algo.run(graph, 0, 0);

      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          final a = nodes[i];
          final b = nodes[j];
          final cx = (a.x + a.width / 2) - (b.x + b.width / 2);
          final cy = (a.y + a.height / 2) - (b.y + b.height / 2);
          final minDx = (a.width + b.width) / 2 + 8;
          final minDy = (a.height + b.height) / 2 + 8;
          expect(cx.abs() < minDx && cy.abs() < minDy, isFalse);
        }
      }
    });
  });
}
