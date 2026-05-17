import 'dart:typed_data';

import 'csr.dart';
import 'ids.dart';
import 'mutable_graph_state.dart';
import 'prop_value.dart';
import 'property_store.dart';
import 'secondary_index/index_size_event.dart';
import 'secondary_index/index_spec.dart';
import 'secondary_index/secondary_index.dart';

/// Public facade over the engine (plan §7.1).
///
/// Phase-1 entry points only — there are no mutations and no
/// persistence here yet. Future phases add `GraphDb.open(path: ...)` for
/// WAL-backed durability, `runInTransaction` for writes, and
/// `executeQuery` for GQL. The read API surfaced here is the locked
/// design from plan §5: the **primitive range** layer is the core, with
/// a callback-based "for each" sugar layer on top.
class GraphDb {
  final MutableGraphState _state;

  GraphDb._(this._state);

  /// Wraps an already-built [MutableGraphState] — the Phase-1 entry
  /// point. Fixture loaders (e.g. `SocialGraph.build()` from
  /// `package:graph_db_core/samples.dart`) hand back a [GraphDb] this way.
  factory GraphDb.fromState(MutableGraphState state) => GraphDb._(state);

  /// Underlying state — for advanced callers and tests. The public API
  /// here covers the documented Phase-1 surface; Phase 2 will lock this
  /// behind the transaction model.
  MutableGraphState get state => _state;

  /// CSR — exposed so callers writing extremely tight loops can index
  /// the typed arrays directly (plan §5 primitive layer).
  Csr get csr => _state.csr;

  // ---------------------------------------------------------------- catalog

  int internLabel(String name) => _state.strings.internLabel(name);
  int internEdgeType(String name) => _state.strings.internEdgeType(name);
  int internPropKey(String name) => _state.strings.internPropKey(name);

  String? labelName(int id) => _state.strings.labelOf(id);
  String? edgeTypeName(int id) => _state.strings.edgeTypeOf(id);
  String? propKeyName(int id) => _state.strings.propKeyOf(id);

  // -------------------------------------------------------------- topology

  int get nodeCount => _state.csr.nodeCount;
  int get edgeCount => _state.csr.edgeCount;
  int outDegree(Vid vid) => _state.csr.outDegree(vid.value);
  int inDegree(Vid vid) => _state.csr.inDegree(vid.value);
  int labelOf(Vid vid) => _state.csr.labelOf[vid.value];

  // ------------------------------------------------------------- traversal
  // Primitive range API — allocation-free, fastest on AOT (Spike A).

  int outRangeStart(Vid vid) => _state.outStart(vid);
  int outRangeEnd(Vid vid) => _state.outEnd(vid);
  Vid outNeighborAt(int i) => _state.outNeighborAt(i);
  Eid edgeIdAt(int i) => _state.edgeIdAt(i);
  int edgeTypeAt(int i) => _state.edgeTypeAt(i);

  int inRangeStart(Vid vid) => _state.inStart(vid);
  int inRangeEnd(Vid vid) => _state.inEnd(vid);
  Vid inNeighborAt(int i) => _state.inNeighborAt(i);
  Eid inEdgeIdAt(int i) => _state.inEdgeIdAt(i);
  int inEdgeTypeAt(int i) => _state.inEdgeTypeAt(i);

  /// Callback sugar — invokes [visit] for each out-edge of [vid].
  ///
  /// Hoist [visit] to a top-level function or a field-bound closure to
  /// keep this path allocation-free (Spike A: callback shape is
  /// gc/op 0.000 when the closure is prebuilt).
  void forEachOutNeighbor(
    Vid vid,
    void Function(Vid dst, Eid eid, int edgeType) visit,
  ) {
    final csr = _state.csr;
    final end = csr.rowPtrOut[vid.value + 1];
    for (var i = csr.rowPtrOut[vid.value]; i < end; i++) {
      visit(
        Vid(csr.colIdxOut[i]),
        Eid(csr.edgeIdOut[i]),
        csr.edgeTypeOut[i],
      );
    }
  }

  /// Callback sugar — invokes [visit] for each in-edge of [vid].
  void forEachInNeighbor(
    Vid vid,
    void Function(Vid src, Eid eid, int edgeType) visit,
  ) {
    final csr = _state.csr;
    final end = csr.rowPtrIn[vid.value + 1];
    for (var i = csr.rowPtrIn[vid.value]; i < end; i++) {
      visit(
        Vid(csr.colIdxIn[i]),
        Eid(csr.edgeIdIn[i]),
        csr.edgeTypeIn[i],
      );
    }
  }

  // ---------------------------------------------------------------- labels

  /// All vids carrying [labelId], in ascending order. The returned
  /// [Uint32List] is a view into a pre-built sorted index — do not
  /// mutate it.
  Uint32List labelScan(int labelId) => _state.labelScan(labelId);

  // --------------------------------------------------------- property reads
  //
  // Raw primitives — caller knows the type (`columnType` on the
  // property store) or guards via [hasNodeProp] / [nodePropIsNull].
  // Use [getNodeProp] / [getEdgeProp] for the boxed boundary form.

  bool hasNodeProp(Vid vid, int keyId) => _state.hasNodeProp(vid, keyId);
  bool nodePropIsNull(Vid vid, int keyId) =>
      _state.nodeProps.isNull(vid.value, keyId);
  ColumnType? nodePropType(int keyId) =>
      _state.nodeProps.columnType(keyId);

  int getNodeIntProp(Vid vid, int keyId) =>
      _state.getNodeIntProp(vid, keyId);
  double getNodeDoubleProp(Vid vid, int keyId) =>
      _state.getNodeDoubleProp(vid, keyId);
  bool getNodeBoolProp(Vid vid, int keyId) =>
      _state.getNodeBoolProp(vid, keyId);
  String getNodeStringProp(Vid vid, int keyId) =>
      _state.getNodeStringProp(vid, keyId);

  bool hasEdgeProp(Eid eid, int keyId) => _state.hasEdgeProp(eid, keyId);
  ColumnType? edgePropType(int keyId) =>
      _state.edgeProps.columnType(keyId);

  int getEdgeIntProp(Eid eid, int keyId) =>
      _state.getEdgeIntProp(eid, keyId);
  String getEdgeStringProp(Eid eid, int keyId) =>
      _state.getEdgeStringProp(eid, keyId);

  /// Boundary read — constructs and returns a [PropValue]. Allocates;
  /// use the typed primitive accessors above on the hot path.
  PropValue? getNodeProp(Vid vid, int keyId) =>
      _state.nodeProps.getBoxed(vid.value, keyId);
  PropValue? getEdgeProp(Eid eid, int keyId) =>
      _state.edgeProps.getBoxed(eid.value, keyId);

  // ----- Secondary indexes (plan §3.3) -------------------------------------

  /// Soft-budget size-event hook (plan §3.3). Default unset = silent.
  /// Wire a logger or a test assertion sink here to be notified when
  /// a freshly-built index crosses the [kIndexSizeWarnThreshold]
  /// ratio of [Csr.sizeBytes]. Fired once per `createIndex()`.
  IndexSizeListener? onIndexSizeEvent;

  /// Builds a node-property index from the current state. Fires
  /// [onIndexSizeEvent] if the new index is at or above the soft
  /// budget. Phase 1 is read-only — the index reflects the loaded
  /// fixture and does not update with mutations (Phase 5 wires
  /// incremental update).
  SecondaryIndex createNodePropertyIndex(IndexSpec spec) =>
      _state.createNodePropertyIndex(spec, onSizeEvent: onIndexSizeEvent);

  /// Builds an edge-property index from the current state. See
  /// [createNodePropertyIndex] for semantics.
  SecondaryIndex createEdgePropertyIndex(IndexSpec spec) =>
      _state.createEdgePropertyIndex(spec, onSizeEvent: onIndexSizeEvent);

  /// Looks up a registered node-property index by name.
  SecondaryIndex? getNodeIndex(String name) => _state.getNodeIndex(name);

  /// Looks up a registered edge-property index by name.
  SecondaryIndex? getEdgeIndex(String name) => _state.getEdgeIndex(name);

  /// Removes a node-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropNodeIndex(String name) => _state.dropNodeIndex(name);

  /// Removes an edge-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropEdgeIndex(String name) => _state.dropEdgeIndex(name);
}
