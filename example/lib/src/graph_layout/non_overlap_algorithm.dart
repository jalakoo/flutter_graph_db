import 'package:flutter/painting.dart';
import 'package:graphview/GraphView.dart';

/// Subclass of [FruchtermanReingoldAlgorithm] that **guarantees no two
/// node AABBs overlap**.
///
/// graphview's force-directed layout balances repulsion + attraction
/// heuristically; under dense connectivity it can still leave nodes
/// touching or overlapping. After the base FR pass converges, this
/// algorithm runs a deterministic AABB-separation pass that
/// iteratively pushes each overlapping pair apart by their
/// **minimum translation vector** until no pair overlaps (or a
/// safety cap is hit).
///
/// Complexity: O(passes · N²). For the example's social fixture
/// (16 nodes) that's microseconds; for thousands of nodes the
/// quadratic pass would dominate and a spatial-hash variant would be
/// appropriate.
class NonOverlapFruchtermanReingoldAlgorithm
    extends FruchtermanReingoldAlgorithm {
  /// Minimum gap (in layout units) preserved between any two node
  /// AABBs after resolution. Bigger ⇒ more breathing room, larger
  /// canvas.
  final double padding;

  /// Cap on the number of separation passes. Convergence in practice
  /// is well under this for realistic graphs.
  final int maxOverlapPasses;

  NonOverlapFruchtermanReingoldAlgorithm(
    super.configuration, {
    super.renderer,
    this.padding = 16,
    this.maxOverlapPasses = 200,
  });

  @override
  Size run(Graph? graph, double shiftX, double shiftY) {
    final size = super.run(graph, shiftX, shiftY);
    if (graph == null) return size;
    _resolveOverlaps(graph);
    // Node positions may have shifted negative during separation —
    // normalise back to (0, 0) and report the new canvas extent.
    return _normaliseAndMeasure(graph);
  }

  bool _overlaps(Node a, Node b) {
    final cx = (a.x + a.width / 2) - (b.x + b.width / 2);
    final cy = (a.y + a.height / 2) - (b.y + b.height / 2);
    final minDx = (a.width + b.width) / 2 + padding;
    final minDy = (a.height + b.height) / 2 + padding;
    return cx.abs() < minDx && cy.abs() < minDy;
  }

  /// Pushes [a] and [b] apart along the **minimum translation vector**
  /// — i.e. along whichever axis (x or y) has the smaller overlap. This
  /// is the textbook AABB collision resolution; it produces deterministic,
  /// orthogonal nudges that avoid the "jitter forever" pathology of
  /// purely radial separation.
  void _separate(Node a, Node b) {
    final acx = a.x + a.width / 2;
    final acy = a.y + a.height / 2;
    final bcx = b.x + b.width / 2;
    final bcy = b.y + b.height / 2;
    final cx = bcx - acx;
    final cy = bcy - acy;
    final minDx = (a.width + b.width) / 2 + padding;
    final minDy = (a.height + b.height) / 2 + padding;
    final overlapX = minDx - cx.abs();
    final overlapY = minDy - cy.abs();
    if (overlapX <= 0 || overlapY <= 0) return; // safety — not overlapping

    double pushX = 0;
    double pushY = 0;
    if (overlapX < overlapY) {
      // Resolve along x. If centres coincide, pick a deterministic
      // direction so the loop terminates.
      final dir = cx >= 0 ? 1.0 : -1.0;
      pushX = dir * (overlapX / 2 + 0.5);
    } else {
      final dir = cy >= 0 ? 1.0 : -1.0;
      pushY = dir * (overlapY / 2 + 0.5);
    }
    a.position = Offset(a.x - pushX, a.y - pushY);
    b.position = Offset(b.x + pushX, b.y + pushY);
  }

  void _resolveOverlaps(Graph graph) {
    final nodes = graph.nodes;
    for (var pass = 0; pass < maxOverlapPasses; pass++) {
      var moved = false;
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          if (_overlaps(nodes[i], nodes[j])) {
            _separate(nodes[i], nodes[j]);
            moved = true;
          }
        }
      }
      if (!moved) return;
    }
  }

  Size _normaliseAndMeasure(Graph graph) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final n in graph.nodes) {
      if (n.x < minX) minX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.x + n.width > maxX) maxX = n.x + n.width;
      if (n.y + n.height > maxY) maxY = n.y + n.height;
    }
    if (minX < 0 || minY < 0) {
      final dx = minX < 0 ? -minX : 0.0;
      final dy = minY < 0 ? -minY : 0.0;
      for (final n in graph.nodes) {
        n.position = Offset(n.x + dx, n.y + dy);
      }
      maxX += dx;
      maxY += dy;
    }
    return Size(maxX, maxY);
  }
}
