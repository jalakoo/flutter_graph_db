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
/// **Scope today:** CSR + node/edge property columns + interner +
/// constraint catalog. Overlay state is **merged before snapshot**
/// (clean state — no per-vid deltas to encode); indexes are
/// rebuilt on read (`priority: high` index persistence is the next
/// polish step on top of this format).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../constraints/constraint.dart';
import '../csr.dart';
import '../mutable_graph_state.dart';
import '../property_store.dart';
import '../string_interner.dart';
import '../wal_op.dart' show ConstraintKind;

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
const int _kVersion = 2;

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
    },
    'nodeProps': _dumpPropertyStore(state.nodeProps),
    'edgeProps': _dumpPropertyStore(state.edgeProps),
    'constraints': _dumpConstraints(state.constraints.all.toList()),
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
  if (version != _kVersion && version != 1) {
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
  for (final keyId in store.declaredKeyIds) {
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

/// Surfaces the per-store keyId iteration — kept here (rather than
/// on `PropertyStore`) because the snapshot is the only public
/// consumer. A future polish step may promote this to a `PropertyStore`
/// public iterator.
extension on PropertyStore {
  Iterable<int> get declaredKeyIds sync* {
    // PropertyStore exposes `columnCount` + `hasColumn(keyId)`;
    // we use the interner-driven keyId space — the snapshot caller
    // walks every keyId from 0 to a reasonable upper bound and
    // skips uncovered ones. For v1 simplicity, we iterate up to a
    // bounded keyId range. The caller (encodeSnapshot) supplies
    // the upper bound via the interner's propKeyCount; here we
    // re-derive by scanning until columnCount holes.
    for (var k = 0; columnCount > 0 && k < (columnCount + 256); k++) {
      if (hasColumn(k)) yield k;
    }
  }
}

