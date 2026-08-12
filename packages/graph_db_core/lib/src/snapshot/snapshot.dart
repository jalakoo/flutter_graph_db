/// Snapshot serialization.
///
/// **v1 format = JSON.** A binary format (with typed-list zero-copy)
/// is the obvious polish step; JSON ships fast + is trivially
/// inspectable + integrates with `dart:convert`. The snapshot
/// captures the current state in full so recovery doesn't have to
/// replay the WAL from origin — paired with the segment-aligned WAL
/// truncate, this bounds startup cost to one snapshot read + the tail
/// of the WAL since the snapshot.
///
/// **Scope today:** CSR (including node tombstones) + node/edge property
/// columns + interner + constraint catalog + index declarations. Overlay
/// state is **merged before snapshot** (clean state — no per-vid deltas to
/// encode). Index *contents* are derived: the declarations round-trip and
/// each index is rebuilt from the restored columns on decode. Persisting
/// the built arrays to skip that rebuild (`priority: high`) is the next
/// polish step on top of this format.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../constraints/constraint.dart';
import '../csr.dart';
import '../mutable_graph_state.dart';
import '../property_store.dart';
import '../secondary_index/index_spec.dart';
import '../string_interner.dart';
import '../wal_op.dart' show ConstraintKind, PropertyOwner;

/// Metadata captured at snapshot time. Persisted by the caller (e.g.
/// alongside the WAL) so recovery knows the LSN the snapshot was
/// taken at.
class SnapshotMeta {
  final int lsn;
  final DateTime takenAt;
  final int sizeBytes;

  const SnapshotMeta({
    required this.lsn,
    required this.takenAt,
    required this.sizeBytes,
  });

  @override
  String toString() =>
      'SnapshotMeta(lsn: $lsn, takenAt: $takenAt, '
      'sizeBytes: $sizeBytes)';
}

/// Magic header — caller validates this before attempting a decode.
const String _kMagic = 'GDBSNAP';

/// Snapshot version.
///
/// **v1** — single-label `'labelOf'` field on the `csr` section.
/// **v2** — ragged labels (`'labelRowPtr'` + `'labels'`); multi-label
/// rollout. The decoder accepts both; v1 is silently upgraded by
/// synthesising rows of length 1. Per §19.6 of the multi-label plan
/// the v1 fallback decode is retained for two minor versions, then
/// removed.
/// **v3** — `'nodeTombstones'` on the `csr` section (sparse: the list of
/// deleted vids). v1 / v2 snapshots decode with no tombstones, which
/// matches what they could express — they predate tombstone persistence,
/// so a node deleted before the snapshot was taken came back on load.
const int _kVersion = 3;

/// Versions this decoder accepts.
const Set<int> _kReadableVersions = {1, 2, 3};

/// Encodes [state] into a self-describing JSON blob. The state's
/// overlay must already be merged (see [MutableGraphState.mergeNow])
/// — encoding fails fast if it isn't, so a snapshot never carries
/// half-applied mutations.
({Uint8List bytes, SnapshotMeta meta}) encodeSnapshot(
  MutableGraphState state,
) {
  if (!state.overlay.isEmpty) {
    throw StateError(
      'encodeSnapshot called with a non-empty overlay — call '
      '`state.mergeNow()` first so the snapshot is consistent',
    );
  }
  final csr = state.csr;
  final root = <String, Object?>{
    'magic': _kMagic,
    'v': _kVersion,
    'meta': {
      'nextVid': state.nextVid,
      'nextEid': state.nextEid,
      'nextLsn': state.nextLsn,
      'nextTxnId': state.nextTxnId,
    },
    'intern': {
      'labels': _dumpInternerSpace(state.strings, _InternerKind.label),
      'edgeTypes':
          _dumpInternerSpace(state.strings, _InternerKind.edgeType),
      'propKeys':
          _dumpInternerSpace(state.strings, _InternerKind.propKey),
    },
    'csr': {
      'nodeCount': csr.nodeCount,
      'edgeCount': csr.edgeCount,
      // v2 ragged labels — sorted ascending within each row.
      'labelRowPtr': csr.labelRowPtr.toList(),
      'labels': csr.labels.toList(),
      'edges': _dumpEdges(csr),
      // v3 — deleted vids, as a sparse ascending list (tombstones are
      // rare relative to nodeCount, so a bitmap would waste space).
      // Omitted entirely when nothing is deleted.
      if (csr.nodeTombstones != null) 'nodeTombstones': _dumpTombstones(csr),
    },
    'nodeProps': _dumpPropertyStore(state.nodeProps),
    'edgeProps': _dumpPropertyStore(state.edgeProps),
    'constraints': _dumpConstraints(state.constraints.all.toList()),
    // v3 — index declarations. Contents are derived, so only the specs
    // travel; the decoder rebuilds each index from the restored columns.
    // Without this a snapshot-only open (WAL fully truncated) came back
    // with no indexes at all.
    'indexes': _dumpIndexes(state),
    // Built-in logical-id index, keyed by vid (as a JSON string key).
    'logicalIds': {
      for (final e in state.logicalIdEntries.entries) '${e.key}': e.value,
    },
  };
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(root)));
  return (
    bytes: bytes,
    meta: SnapshotMeta(
      lsn: state.nextLsn - 1,
      takenAt: DateTime.now(),
      sizeBytes: bytes.length,
    ),
  );
}

/// Decodes a snapshot back into a [MutableGraphState]. Throws
/// `FormatException` on a magic / version mismatch.
MutableGraphState decodeSnapshot(Uint8List bytes) {
  final root = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  if (root['magic'] != _kMagic) {
    throw const FormatException('not a graph_db snapshot');
  }
  final version = root['v'];
  if (!_kReadableVersions.contains(version)) {
    throw FormatException('unsupported snapshot version: $version');
  }
  final meta = root['meta']! as Map<String, Object?>;
  final intern = root['intern']! as Map<String, Object?>;
  final csrSection = root['csr']! as Map<String, Object?>;

  // Interner — feed the strings back in order so ids match.
  final strings = StringInterner();
  for (final s in (intern['labels'] as List).cast<String>()) {
    strings.internLabel(s);
  }
  for (final s in (intern['edgeTypes'] as List).cast<String>()) {
    strings.internEdgeType(s);
  }
  for (final s in (intern['propKeys'] as List).cast<String>()) {
    strings.internPropKey(s);
  }

  // CSR — rebuild via Csr.fromEdges. Version 2 carries ragged labels;
  // version 1 carries flat `labelOf` and we synthesise the ragged
  // form (each row length 1).
  final nodeCount = csrSection['nodeCount']! as int;
  final edgeCount = csrSection['edgeCount']! as int;
  final Uint32List labelOf;
  final Uint32List labelRowPtr;
  final Uint32List labels;
  if (csrSection.containsKey('labelRowPtr') &&
      csrSection.containsKey('labels')) {
    labelRowPtr = Uint32List.fromList(
      (csrSection['labelRowPtr']! as List).cast<int>(),
    );
    labels = Uint32List.fromList(
      (csrSection['labels']! as List).cast<int>(),
    );
    // Derive legacy `labelOf` as the first-label-per-vid scalar.
    labelOf = Uint32List(nodeCount);
    for (var v = 0; v < nodeCount; v++) {
      final start = labelRowPtr[v];
      if (start < labelRowPtr[v + 1]) labelOf[v] = labels[start];
    }
  } else {
    // v1 fallback — single-label labelOf, synthesise ragged.
    labelOf = Uint32List.fromList(
      (csrSection['labelOf']! as List).cast<int>(),
    );
    labelRowPtr = Uint32List(nodeCount + 1);
    for (var v = 0; v < nodeCount; v++) {
      labelRowPtr[v + 1] = v + 1;
    }
    labels = Uint32List.fromList(labelOf);
  }
  final edges = (csrSection['edges']! as List).cast<Map<String, Object?>>();
  final srcs = Uint32List(edgeCount);
  final dsts = Uint32List(edgeCount);
  final types = Uint32List(edgeCount);
  final eids = Uint32List(edgeCount);
  for (var i = 0; i < edgeCount; i++) {
    srcs[i] = edges[i]['src']! as int;
    dsts[i] = edges[i]['dst']! as int;
    types[i] = edges[i]['type']! as int;
    eids[i] = edges[i]['eid']! as int;
  }
  var labelCount = 0;
  for (final l in labels) {
    if (l + 1 > labelCount) labelCount = l + 1;
  }
  // v3 tombstones. Absent in v1 / v2 — those formats had no way to say a
  // node was deleted, so they load with every row live.
  Uint8List? nodeTombstones;
  final rawTombstones = csrSection['nodeTombstones'] as List?;
  if (rawTombstones != null && rawTombstones.isNotEmpty) {
    nodeTombstones = Uint8List(nodeCount);
    for (final v in rawTombstones.cast<int>()) {
      if (v < nodeCount) nodeTombstones[v] = 1;
    }
  }
  final csr = Csr.fromEdges(
    nodeCount: nodeCount,
    srcs: srcs,
    dsts: dsts,
    edgeTypes: types,
    labelOf: labelOf,
    labelRowPtr: labelRowPtr,
    labels: labels,
    labelCount: labelCount,
    eids: eids,
    nodeTombstones: nodeTombstones,
  );

  // Property stores.
  final nodeProps = _loadPropertyStore(
    root['nodeProps']! as List,
    vidSpace: (meta['nextVid'] as int).clamp(nodeCount, 1 << 30),
  );
  final edgeProps = _loadPropertyStore(
    root['edgeProps']! as List,
    vidSpace: (meta['nextEid'] as int).clamp(edgeCount, 1 << 30),
  );

  final state = MutableGraphState(
    strings: strings,
    csr: csr,
    nodeProps: nodeProps,
    edgeProps: edgeProps,
    nextVid: meta['nextVid']! as int,
    nextEid: meta['nextEid']! as int,
    nextLsn: meta['nextLsn']! as int,
    nextTxnId: meta['nextTxnId']! as int,
  );

  // Constraints.
  for (final c in (root['constraints']! as List).cast<Map<String, Object?>>()) {
    final kind = ConstraintKind.values
        .firstWhere((k) => k.name == c['kind'] as String);
    state.applyDeclareConstraint(
      name: c['name']! as String,
      labelId: c['labelId']! as int,
      keyId: c['keyId']! as int,
      kind: kind,
    );
  }

  // Built-in logical-id index. Absent in pre-logicalId snapshots — skip.
  final lids = root['logicalIds'] as Map<String, Object?>?;
  if (lids != null) {
    for (final e in lids.entries) {
      state.restoreLogicalId(int.parse(e.key), e.value! as String);
    }
  }

  // v3 index declarations. Rebuilt from the restored columns; absent in
  // v1 / v2, which simply had no index persistence.
  final indexes = root['indexes'] as List?;
  if (indexes != null) {
    for (final raw in indexes.cast<Map<String, Object?>>()) {
      final owner = raw['owner'] == 'edge'
          ? PropertyOwner.edge
          : PropertyOwner.node;
      state.applyDeclareIndex(owner, _loadIndexSpec(raw));
    }
  }
  return state;
}

// ---------------------------------------------------------------------------

enum _InternerKind { label, edgeType, propKey }

List<String> _dumpInternerSpace(StringInterner s, _InternerKind kind) {
  final count = switch (kind) {
    _InternerKind.label => s.labelCount,
    _InternerKind.edgeType => s.edgeTypeCount,
    _InternerKind.propKey => s.propKeyCount,
  };
  final get = switch (kind) {
    _InternerKind.label => s.labelOf,
    _InternerKind.edgeType => s.edgeTypeOf,
    _InternerKind.propKey => s.propKeyOf,
  };
  return [for (var i = 0; i < count; i++) get(i)!];
}

/// Deleted vids as a sparse ascending list. Sparse rather than a raw
/// bitmap because tombstones are rare relative to `nodeCount`, and JSON
/// would spend a character per live node either way.
List<int> _dumpTombstones(Csr csr) {
  final t = csr.nodeTombstones!;
  final out = <int>[];
  for (var v = 0; v < t.length; v++) {
    if (t[v] != 0) out.add(v);
  }
  return out;
}

List<Map<String, Object?>> _dumpEdges(Csr csr) {
  final out = <Map<String, Object?>>[];
  for (var v = 0; v < csr.nodeCount; v++) {
    final end = csr.rowPtrOut[v + 1];
    for (var i = csr.rowPtrOut[v]; i < end; i++) {
      out.add({
        'src': v,
        'dst': csr.colIdxOut[i],
        'type': csr.edgeTypeOut[i],
        'eid': csr.edgeIdOut[i],
      });
    }
  }
  return out;
}

List<Map<String, Object?>> _dumpPropertyStore(PropertyStore store) {
  final out = <Map<String, Object?>>[];
  // Sorted so the encoded form is deterministic for a given state —
  // makes snapshot bytes comparable across runs in tests.
  final keyIds = store.columnKeyIds.toList()..sort();
  for (final keyId in keyIds) {
    final type = store.columnType(keyId)!;
    final pairs = <Map<String, Object?>>[];
    void add(int vid, Object value) {
      pairs.add({'vid': vid, 'val': value});
    }

    switch (type) {
      case ColumnType.int_:
        store.forEachSetInt(keyId, (vid, value) => add(vid, value));
      case ColumnType.double_:
        store.forEachSetDouble(keyId, (vid, value) => add(vid, value));
      case ColumnType.bool_:
        store.forEachSetBool(keyId, (vid, value) => add(vid, value));
      case ColumnType.string:
        store.forEachSetString(keyId, (vid, value) => add(vid, value));
      case ColumnType.stringId:
        store.forEachSetStringId(keyId, (vid, value) => add(vid, value));
    }
    out.add({'keyId': keyId, 'type': type.name, 'values': pairs});
  }
  return out;
}

PropertyStore _loadPropertyStore(List<Object?> dump, {required int vidSpace}) {
  final store = PropertyStore(vidSpace: vidSpace);
  for (final col in dump.cast<Map<String, Object?>>()) {
    final keyId = col['keyId']! as int;
    final type = ColumnType.values
        .firstWhere((t) => t.name == col['type'] as String);
    store.createColumn(keyId, type);
    for (final v in (col['values']! as List).cast<Map<String, Object?>>()) {
      final vid = v['vid']! as int;
      final raw = v['val'];
      switch (type) {
        case ColumnType.int_:
          store.setInt(vid, keyId, raw as int);
        case ColumnType.double_:
          store.setDouble(vid, keyId, (raw as num).toDouble());
        case ColumnType.bool_:
          store.setBool(vid, keyId, raw as bool);
        case ColumnType.string:
          store.setString(vid, keyId, raw as String);
        case ColumnType.stringId:
          store.setStringId(vid, keyId, raw as int);
      }
    }
  }
  return store;
}

List<Map<String, Object?>> _dumpIndexes(MutableGraphState state) {
  return [
    for (final e in state.declaredIndexes)
      {
        'owner': e.owner.name,
        'name': e.spec.name,
        'keyId': e.spec.keyId,
        'priority': e.spec.priority.name,
        if (e.spec.valueType != null) 'valueType': e.spec.valueType!.name,
        if (e.spec.labelScope != null) 'labelScope': e.spec.labelScope,
        'kind': switch (e.spec.kind) {
          EqualityRange(
            :final hashOverlay,
            :final unique,
            :final deferred,
            :final incremental,
          ) =>
            {
              'k': 'EqualityRange',
              'hashOverlay': hashOverlay,
              'unique': unique,
              'deferred': deferred,
              'incremental': incremental,
            },
        },
      },
  ];
}

IndexSpec _loadIndexSpec(Map<String, Object?> raw) {
  final rawKind = raw['kind']! as Map<String, Object?>;
  final IndexKind kind = switch (rawKind['k']) {
    'EqualityRange' => EqualityRange(
        hashOverlay: rawKind['hashOverlay']! as bool,
        unique: rawKind['unique']! as bool,
        deferred: rawKind['deferred']! as bool,
        incremental: rawKind['incremental']! as bool,
      ),
    final other => throw FormatException('unknown IndexKind tag: $other'),
  };
  final valueType = raw['valueType'] as String?;
  return IndexSpec(
    name: raw['name']! as String,
    keyId: raw['keyId']! as int,
    kind: kind,
    priority: IndexPriority.values.firstWhere(
      (p) => p.name == raw['priority'],
      orElse: () => IndexPriority.low,
    ),
    valueType: valueType == null
        ? null
        : ColumnType.values.firstWhere((t) => t.name == valueType),
    labelScope: raw['labelScope'] as int?,
  );
}

List<Map<String, Object?>> _dumpConstraints(List<ConstraintSpec> specs) {
  return [
    for (final s in specs)
      {
        'name': s.name,
        'labelId': s.labelId,
        'keyId': s.keyId,
        'kind': switch (s) {
          UniqueConstraint() => ConstraintKind.unique.name,
          ExistenceConstraint() => ConstraintKind.existence.name,
        },
      },
  ];
}


