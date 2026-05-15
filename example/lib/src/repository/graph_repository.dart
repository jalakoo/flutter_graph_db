import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:graph_db_core/graph_db_core.dart';
import 'package:path_provider/path_provider.dart';

import '../data/engine_view.dart';
import '../data/graph_data.dart';

/// Mutation-aware container for the example's graph state.
///
/// Owns the JSON [GraphData], rebuilds an [EngineView] over the engine
/// after every commit, and persists the data to the app documents
/// directory so changes survive a relaunch. Mutations are synchronous
/// in-memory; the JSON write is fire-and-forget.
///
/// This is the example's stand-in for the real `graph_db_wal` (plan §6):
/// JSON instead of CBOR, no WAL framing, snapshot-on-every-mutation
/// instead of append-only. Production callers will swap this layer for
/// the WAL-backed `GraphDb.open(path: ...)` once Phase 2 lands.
class GraphRepository extends ChangeNotifier {
  static const String _fileName = 'graph_db_example_v1.json';

  GraphData _data;
  EngineView _view;
  final File? _file;

  /// Monotonic counter bumped on every successful commit. Lets external
  /// observers (e.g. the home shell) detect "did the data change since
  /// the last time I looked at it" without subscribing to every notify.
  int _commitCount = 0;
  int get commitCount => _commitCount;

  GraphRepository._(this._data, this._file) : _view = _data.buildEngineView();

  /// Opens (or initializes) the repository. Reads the persisted JSON
  /// snapshot if it exists; otherwise seeds from [GraphData.socialFixture].
  ///
  /// Pass [file] = null in tests to skip disk I/O entirely.
  static Future<GraphRepository> open({File? file}) async {
    final target = file ?? await _defaultFile();
    GraphData data;
    if (target != null && await target.exists()) {
      try {
        final raw = await target.readAsString();
        data = GraphData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e, st) {
        debugPrint('graph_db_example: failed to load snapshot, '
            'falling back to the fixture: $e\n$st');
        data = GraphData.socialFixture();
      }
    } else {
      data = GraphData.socialFixture();
    }
    return GraphRepository._(data, target);
  }

  /// In-memory repository — no persistence. Used by widget tests.
  factory GraphRepository.inMemory([GraphData? seed]) =>
      GraphRepository._(seed ?? GraphData.socialFixture(), null);

  static Future<File?> _defaultFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/$_fileName');
    } catch (e) {
      // Platforms without path_provider (e.g. some test runners) get
      // an in-memory repository with no persistence.
      debugPrint('graph_db_example: no application documents directory '
          '($e); running without persistence.');
      return null;
    }
  }

  // ----- Public surface ------------------------------------------------------

  EngineView get view => _view;
  GraphDb get db => _view.db;
  GraphData get data => _data;
  bool get isPersisting => _file != null;

  // ----- Mutations -----------------------------------------------------------

  /// Adds a new Person with the given properties. Returns the new vid.
  Vid addPerson({
    required String name,
    required int age,
    required String title,
  }) {
    _data.nodes.add(NodeRecord(
      labelId: 0, // Person — fixed by catalog order
      props: {'name': name, 'age': age, 'title': title},
    ));
    _commit();
    return Vid(_data.nodes.length - 1);
  }

  /// Updates an existing Person's properties. Any null parameter is
  /// left unchanged.
  void editPerson(
    Vid vid, {
    String? name,
    int? age,
    String? title,
  }) {
    final n = _data.nodes[vid.value];
    if (n.deleted) {
      throw StateError('cannot edit tombstoned vid ${vid.value}');
    }
    if (name != null) n.props['name'] = name;
    if (age != null) n.props['age'] = age;
    if (title != null) n.props['title'] = title;
    _commit();
  }

  /// Deletes a node (Person or Company) and cascades all incident edges
  /// — matches plan §3.6 ("monotonic from 0, never reused on delete").
  void deleteNode(Vid vid) {
    final n = _data.nodes[vid.value];
    if (n.deleted) return;
    n.deleted = true;
    for (final e in _data.edges) {
      if (!e.deleted && (e.src == vid.value || e.dst == vid.value)) {
        e.deleted = true;
      }
    }
    _commit();
  }

  /// Adds a directed `knows` edge between two existing people.
  /// No-op if either endpoint is deleted or the edge already exists.
  Eid? addKnows(Vid src, Vid dst) {
    final n1 = _data.nodes[src.value];
    final n2 = _data.nodes[dst.value];
    if (n1.deleted || n2.deleted) return null;
    if (src.value == dst.value) return null;
    final knowsType =
        _data.edgeTypeNames.indexOf('knows'); // catalog-stable index
    for (final e in _data.edges) {
      if (!e.deleted &&
          e.src == src.value &&
          e.dst == dst.value &&
          e.typeId == knowsType) {
        return Eid(_data.edges.indexOf(e));
      }
    }
    _data.edges.add(EdgeRecord(
      src: src.value,
      dst: dst.value,
      typeId: knowsType,
      props: {},
    ));
    _commit();
    return Eid(_data.edges.length - 1);
  }

  /// Removes the directed `knows` edge `src -> dst` if it exists.
  void removeKnows(Vid src, Vid dst) {
    final knowsType = _data.edgeTypeNames.indexOf('knows');
    var dirty = false;
    for (final e in _data.edges) {
      if (!e.deleted &&
          e.src == src.value &&
          e.dst == dst.value &&
          e.typeId == knowsType) {
        e.deleted = true;
        dirty = true;
        break;
      }
    }
    if (dirty) _commit();
  }

  /// Adds a new Company. Returns the new vid.
  Vid addCompany({required String name, required int foundedYear}) {
    _data.nodes.add(NodeRecord(
      labelId: 1, // Company — fixed by catalog order
      props: {'name': name, 'foundedYear': foundedYear},
    ));
    _commit();
    return Vid(_data.nodes.length - 1);
  }

  /// Updates Company properties. Null parameters are left unchanged.
  void editCompany(Vid vid, {String? name, int? foundedYear}) {
    final n = _data.nodes[vid.value];
    if (n.deleted) {
      throw StateError('cannot edit tombstoned vid ${vid.value}');
    }
    if (name != null) n.props['name'] = name;
    if (foundedYear != null) n.props['foundedYear'] = foundedYear;
    _commit();
  }

  /// Replaces [person]'s `worksAt` edge with one pointing to [company].
  /// Pass `null` for [company] to remove the existing edge entirely
  /// (treats `worksAt` as single-valued — matches the fixture).
  void setWorksAt(Vid person, Vid? company) {
    final worksAtType = _data.edgeTypeNames.indexOf('worksAt');
    var dirty = false;
    for (final e in _data.edges) {
      if (!e.deleted && e.src == person.value && e.typeId == worksAtType) {
        // If the existing edge already points at the target, nothing to do.
        if (company != null && e.dst == company.value) return;
        e.deleted = true;
        dirty = true;
      }
    }
    if (company != null) {
      _data.edges.add(EdgeRecord(
        src: person.value,
        dst: company.value,
        typeId: worksAtType,
        props: {},
      ));
      dirty = true;
    }
    if (dirty) _commit();
  }

  /// Adds a `founded` edge from [person] to [company]. No-op if the edge
  /// already exists or either endpoint is tombstoned.
  Eid? addFounded(Vid person, Vid company) {
    final n1 = _data.nodes[person.value];
    final n2 = _data.nodes[company.value];
    if (n1.deleted || n2.deleted) return null;
    final foundedType = _data.edgeTypeNames.indexOf('founded');
    for (final e in _data.edges) {
      if (!e.deleted &&
          e.src == person.value &&
          e.dst == company.value &&
          e.typeId == foundedType) {
        return Eid(_data.edges.indexOf(e));
      }
    }
    _data.edges.add(EdgeRecord(
      src: person.value,
      dst: company.value,
      typeId: foundedType,
      props: {},
    ));
    _commit();
    return Eid(_data.edges.length - 1);
  }

  /// Removes the `founded` edge `person -> company` if present.
  void removeFounded(Vid person, Vid company) {
    final foundedType = _data.edgeTypeNames.indexOf('founded');
    for (final e in _data.edges) {
      if (!e.deleted &&
          e.src == person.value &&
          e.dst == company.value &&
          e.typeId == foundedType) {
        e.deleted = true;
        _commit();
        return;
      }
    }
  }

  /// Drops every mutation and reloads the original fixture. The
  /// persisted snapshot file (if any) is deleted.
  Future<void> reset() async {
    _data = GraphData.socialFixture();
    _view = _data.buildEngineView();
    _commitCount++;
    final f = _file;
    if (f != null && await f.exists()) {
      try {
        await f.delete();
      } catch (_) {
        // Best-effort.
      }
    }
    notifyListeners();
  }

  // ----- Internal ------------------------------------------------------------

  /// Rebuilds [view] from the mutated [_data], persists asynchronously,
  /// and notifies listeners synchronously so the UI updates immediately.
  void _commit() {
    _view = _data.buildEngineView();
    _commitCount++;
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> _persist() async {
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_data.toJson()), flush: true);
    } catch (e, st) {
      debugPrint('graph_db_example: failed to persist: $e\n$st');
    }
  }
}
