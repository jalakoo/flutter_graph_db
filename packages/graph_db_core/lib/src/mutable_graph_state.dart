import 'dart:typed_data';

import 'csr.dart';
import 'exceptions.dart';
import 'ids.dart';
import 'property_store.dart';
import 'secondary_index/index_size_event.dart';
import 'secondary_index/index_spec.dart';
import 'secondary_index/secondary_index.dart';
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

  // ----- Secondary index registry (plan §3.3) ------------------------------
  //
  // Built once from the current column state — Phase 1 is read-only.
  // Phase 5 will revisit incremental update + the deferred build via the
  // §2.3 worker hand-off.

  final Map<String, SecondaryIndex> _nodeIndexes = {};
  final Map<String, SecondaryIndex> _edgeIndexes = {};

  /// Read-only view of the registered node-property indexes.
  Map<String, SecondaryIndex> get nodeIndexes =>
      Map.unmodifiable(_nodeIndexes);

  /// Read-only view of the registered edge-property indexes.
  Map<String, SecondaryIndex> get edgeIndexes =>
      Map.unmodifiable(_edgeIndexes);

  /// Builds a node-property index from the current [nodeProps] column.
  ///
  /// Fires [onSizeEvent] **once** if the freshly-built index size is at
  /// or above [kIndexSizeWarnThreshold] of [csr.sizeBytes] (plan §3.3
  /// soft budget). [onSizeEvent] is optional; pass `null` (default) to
  /// silently build.
  ///
  /// Throws [ConstraintViolation] if an index named [IndexSpec.name]
  /// already exists, or if the column type isn't yet declared.
  SecondaryIndex createNodePropertyIndex(
    IndexSpec spec, {
    IndexSizeListener? onSizeEvent,
  }) =>
      _createIndex(_nodeIndexes, nodeProps, spec, onSizeEvent);

  /// Builds an edge-property index from the current [edgeProps] column.
  /// See [createNodePropertyIndex] for semantics.
  SecondaryIndex createEdgePropertyIndex(
    IndexSpec spec, {
    IndexSizeListener? onSizeEvent,
  }) =>
      _createIndex(_edgeIndexes, edgeProps, spec, onSizeEvent);

  SecondaryIndex _createIndex(
    Map<String, SecondaryIndex> registry,
    PropertyStore store,
    IndexSpec spec,
    IndexSizeListener? onSizeEvent,
  ) {
    if (registry.containsKey(spec.name)) {
      throw ConstraintViolation('index "${spec.name}" already exists');
    }
    final colType = store.columnType(spec.keyId);
    if (colType == null) {
      throw ConstraintViolation(
          'cannot build index "${spec.name}": no column declared for '
          'keyId ${spec.keyId}');
    }

    final SecondaryIndex idx;
    switch (spec.kind) {
      case EqualityRange(:final hashOverlay):
        switch (colType) {
          case ColumnType.int_:
            idx = IntEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.double_:
            idx = DoubleEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.stringId:
            idx = StringIdEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.string:
            idx = StringEqualityRangeIndex.build(
              spec: spec,
              store: store,
              hashOverlay: hashOverlay,
            );
          case ColumnType.bool_:
            idx = BoolEqualityRangeIndex.build(
              spec: spec,
              store: store,
            );
        }
    }

    registry[spec.name] = idx;

    if (onSizeEvent != null) {
      final csrBytes = csr.sizeBytes;
      final ratio = csrBytes == 0 ? 0.0 : idx.sizeBytes / csrBytes;
      if (ratio >= kIndexSizeWarnThreshold) {
        onSizeEvent(IndexSizeEvent(
          spec: spec,
          indexBytes: idx.sizeBytes,
          csrBytes: csrBytes,
          ratio: ratio,
          severity: IndexSizeSeverity.warn,
        ));
      }
    }
    return idx;
  }

  /// Looks up a registered node-property index by name.
  SecondaryIndex? getNodeIndex(String name) => _nodeIndexes[name];

  /// Looks up a registered edge-property index by name.
  SecondaryIndex? getEdgeIndex(String name) => _edgeIndexes[name];

  /// Removes a node-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropNodeIndex(String name) => _nodeIndexes.remove(name);

  /// Removes an edge-property index from the registry. Returns the
  /// removed index, or `null` if no such index existed.
  SecondaryIndex? dropEdgeIndex(String name) => _edgeIndexes.remove(name);
}
