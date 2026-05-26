/// A narrow, read-only window onto committed graph state (plan A3).
///
/// This is the seam the GQL package reads through instead of reaching
/// into engine internals (the engine's `csr` / `overlay` / `nodeProps`).
/// `MutableGraphState` implements it; consumers reach it via
/// `GraphDb.readView`.
///
/// **Semantics — committed-as-of-now, overlay-aware, *unguarded*.** Every
/// method reflects committed mutations immediately (read-your-writes, no
/// `mergeNow()` needed). Unlike the guarded `GraphDb` data-read API, these
/// reads do **not** trip the in-transaction read-after-write guard — by
/// design, so a `MATCH … SET n.x = n.y + 1` can evaluate its right-hand
/// side while mutations are buffered in the same transaction.
///
/// All members are reads only — no method here can mutate the graph,
/// open a transaction, or intern a new catalog entry. That keeps the
/// query engine structurally read-only and lets it be unit-tested
/// against a hand-written fake (no `GraphDb` / WAL required).
library;

import 'ids.dart';
import 'prop_value.dart';

/// The read-only contract the query engine depends on. Implement (do not
/// extend) to provide a fake in tests.
abstract interface class GraphReadView {
  /// Every visible vid — base-CSR rows minus tombstones, plus
  /// overlay-added nodes. Order is unspecified.
  Iterable<Vid> scanNodes();

  /// Every visible vid whose effective label set contains **all** of
  /// [labelIds] (AND semantics). An empty [labelIds] is equivalent to
  /// [scanNodes]. Folds in overlay-added nodes and label-overrides; skips
  /// tombstoned vids. Order is unspecified.
  Iterable<Vid> labelScanAll(List<int> labelIds);

  /// Invokes [visit] for each live outgoing edge of [vid] — `(dst, eid,
  /// edgeType)`. Overlay-aware; allocation-free in the inner loop.
  void forEachOutNeighbor(
    Vid vid,
    void Function(Vid dst, Eid eid, int edgeType) visit,
  );

  /// Invokes [visit] for each live incoming edge of [vid] — `(src, eid,
  /// edgeType)`. Overlay-aware.
  void forEachInNeighbor(
    Vid vid,
    void Function(Vid src, Eid eid, int edgeType) visit,
  );

  /// Effective label-id set carried by [vid]. Overlay-aware.
  Iterable<int> labelsOf(Vid vid);

  /// True iff [vid] effectively carries [labelId]. Overlay-aware.
  bool hasLabel(Vid vid, int labelId);

  /// Boxed node property at [keyId], or `null` when absent.
  PropValue? nodeProp(Vid vid, int keyId);

  /// Boxed edge property at [keyId], or `null` when absent.
  PropValue? edgeProp(Eid eid, int keyId);

  /// Existing label id for [name], or `null` — never interns.
  int? labelId(String name);

  /// Existing edge-type id for [name], or `null` — never interns.
  int? edgeTypeId(String name);

  /// Existing prop-key id for [name], or `null` — never interns.
  int? propKeyId(String name);

  /// Label name for [id], or `null` if unknown.
  String? labelName(int id);
}
