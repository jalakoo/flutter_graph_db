import 'dart:typed_data';

import 'csr.dart';
import 'ids.dart';
import 'property_store.dart';
import 'string_interner.dart';

/// The composed in-memory state the engine reads from (plan §2.1).
///
/// Phase 1: built once from a fixture via [MutableGraphState.fromFixture]
/// and read-only thereafter. Phase 2 adds the mutation path — the
/// `apply(WalOp)` applicator, the delta overlay, and the WAL.
///
/// Read primitives live here as thin wrappers over the underlying [Csr]
/// + [PropertyStore]. The `outRangeStart` / `outRangeEnd` pair is the
/// **primitive range read API** that Spike A picked as the v1 read
/// shape (plan §5, §7.1) — allocation-free, the simplest, and the
/// fastest on AOT.
class MutableGraphState {
  final StringInterner strings;
  final Csr csr;
  final PropertyStore nodeProps;
  final PropertyStore edgeProps;

  MutableGraphState({
    required this.strings,
    required this.csr,
    required this.nodeProps,
    required this.edgeProps,
  });

  /// Builds an in-memory state from a synthetic / loader edge list.
  ///
  /// `labelNames` and `edgeTypeNames` are interned up front so the
  /// `labelOf` and `edgeTypes` arrays can be filled with the resulting
  /// ids by the caller.
  ///
  /// [eids] and [nodeTombstones] are forwarded to [Csr.fromEdges] —
  /// callers that filter deleted entries from `srcs`/`dsts` while keeping
  /// the original vid/eid numbering use these.
  ///
  /// [vidSpace] / [eidSpace] override the size of the underlying property
  /// stores. Defaults track the input but allow headroom for growth
  /// (handy for example apps that mutate after loading a fixture).
  factory MutableGraphState.fromFixture({
    required int nodeCount,
    required Uint32List srcs,
    required Uint32List dsts,
    required Uint32List edgeTypes,
    required Uint32List labelOf,
    required List<String> labelNames,
    required List<String> edgeTypeNames,
    Uint32List? eids,
    Uint8List? nodeTombstones,
    int? vidSpace,
    int? eidSpace,
  }) {
    final strings = StringInterner();
    for (final name in labelNames) {
      strings.internLabel(name);
    }
    for (final name in edgeTypeNames) {
      strings.internEdgeType(name);
    }
    final csr = Csr.fromEdges(
      nodeCount: nodeCount,
      srcs: srcs,
      dsts: dsts,
      edgeTypes: edgeTypes,
      labelOf: labelOf,
      labelCount: labelNames.length,
      eids: eids,
      nodeTombstones: nodeTombstones,
    );
    final effectiveVidSpace = vidSpace ?? nodeCount;
    final effectiveEidSpace = eidSpace ??
        (eids != null && eids.isNotEmpty
            ? (eids.reduce((a, b) => a > b ? a : b) + 1)
            : csr.edgeCount);
    return MutableGraphState(
      strings: strings,
      csr: csr,
      nodeProps: PropertyStore(vidSpace: effectiveVidSpace),
      edgeProps: PropertyStore(vidSpace: effectiveEidSpace),
    );
  }

  // ----- Topology reads — primitive range API (plan §5, Spike A) -----------
  //
  // Caller indexes the shared CSR arrays directly through the `at`
  // accessors. Allocation-free.

  /// Start index of [vid]'s outgoing edges inside [csr.colIdxOut] /
  /// [csr.edgeIdOut] / [csr.edgeTypeOut].
  int outStart(Vid vid) => csr.rowPtrOut[vid.value];

  /// End index (exclusive) of [vid]'s outgoing edges.
  int outEnd(Vid vid) => csr.rowPtrOut[vid.value + 1];

  /// Out-neighbour vid at CSR position [i].
  Vid outNeighborAt(int i) => Vid(csr.colIdxOut[i]);

  /// Edge id at CSR position [i].
  Eid edgeIdAt(int i) => Eid(csr.edgeIdOut[i]);

  /// Edge type id at CSR position [i] (interned via [strings]).
  int edgeTypeAt(int i) => csr.edgeTypeOut[i];

  /// Start index of [vid]'s incoming edges inside the reverse CSR.
  int inStart(Vid vid) => csr.rowPtrIn[vid.value];

  /// End index (exclusive) of [vid]'s incoming edges.
  int inEnd(Vid vid) => csr.rowPtrIn[vid.value + 1];

  /// Incoming neighbour (source) vid at reverse-CSR position [i].
  Vid inNeighborAt(int i) => Vid(csr.colIdxIn[i]);

  /// Edge id at reverse-CSR position [i].
  Eid inEdgeIdAt(int i) => Eid(csr.edgeIdIn[i]);

  /// Edge type at reverse-CSR position [i].
  int inEdgeTypeAt(int i) => csr.edgeTypeIn[i];

  /// All vids carrying [labelId], in ascending order. Allocation-free
  /// (returns a view into a pre-built sorted index).
  Uint32List labelScan(int labelId) =>
      csr.labelIndex[labelId] ?? _emptyU32;

  static final Uint32List _emptyU32 = Uint32List(0);

  // ----- Property reads — raw primitives (plan §3.2) -----------------------

  bool hasNodeProp(Vid vid, int keyId) =>
      nodeProps.has(vid.value, keyId);
  int getNodeIntProp(Vid vid, int keyId) =>
      nodeProps.getInt(vid.value, keyId);
  double getNodeDoubleProp(Vid vid, int keyId) =>
      nodeProps.getDouble(vid.value, keyId);
  bool getNodeBoolProp(Vid vid, int keyId) =>
      nodeProps.getBool(vid.value, keyId);
  String getNodeStringProp(Vid vid, int keyId) =>
      nodeProps.getString(vid.value, keyId);
  int getNodeStringIdProp(Vid vid, int keyId) =>
      nodeProps.getStringId(vid.value, keyId);

  bool hasEdgeProp(Eid eid, int keyId) =>
      edgeProps.has(eid.value, keyId);
  int getEdgeIntProp(Eid eid, int keyId) =>
      edgeProps.getInt(eid.value, keyId);
  double getEdgeDoubleProp(Eid eid, int keyId) =>
      edgeProps.getDouble(eid.value, keyId);
  bool getEdgeBoolProp(Eid eid, int keyId) =>
      edgeProps.getBool(eid.value, keyId);
  String getEdgeStringProp(Eid eid, int keyId) =>
      edgeProps.getString(eid.value, keyId);
  int getEdgeStringIdProp(Eid eid, int keyId) =>
      edgeProps.getStringId(eid.value, keyId);
}
