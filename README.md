# flutter_graph_db

[![ci](https://github.com/jalakoo/flutter_graph_db/actions/workflows/ci.yaml/badge.svg)](https://github.com/jalakoo/flutter_graph_db/actions/workflows/ci.yaml)

A pure-Dart, Flutter-native embedded graph database — the implementation
of `4_PLAN.md`. See that document for the master plan, priorities, and
the spike validation record that underpins every architectural decision
here.

## Status

Phase 1 in-memory read core complete and exercisable. The example app
in `example/` runs against the `SocialGraph` fixture on iOS / Android /
macOS / desktop and demonstrates every Phase-1 read API in real UI. WAL,
mutation path, GQL, sync are next per plan §14.

## Quick start

```sh
# Core unit tests
cd flutter_graph_db/packages/graph_db_core
dart pub get && dart test

# Run the example app (Flutter)
cd ../../example
flutter pub get && flutter run
```

41 unit tests in `graph_db_core` + 3 tests in `graph_db_bench` +
15 widget / unit tests + 1 on-device integration test in `example/`. The example app ships four tabs —
People, Companies, **Graph** (force-directed node-link view via
`package:graphview`), Stats — with detail screens for both Persons and
Companies, **add / edit / delete / reset** across nodes and edges
(`knows` / `worksAt` / `founded`), and JSON snapshot persistence to the
app documents directory. The Graph tab re-keys its layout when the
user re-enters it after the underlying data has changed.

Production WAL persistence is Phase 2 — the JSON snapshot layer here is
an example-only stand-in.

## Layout

```
flutter_graph_db/
  README.md
  analysis_options.yaml            ← shared lints baseline
  packages/
    graph_db_core/                 ← CSR, properties, applicator, public API
    graph_db_wal/                  ← WAL schema, encoding, recovery   (next)
    graph_db_remote/               ← RemoteGraphClient port            (Phase 4)
    graph_db_remote_neo4j/         ← Bolt adapter                       (Phase 4)
    graph_db_remote_falkor/        ← RESP adapter                       (Phase 4)
    graph_db_sync/                 ← Sync engine                        (Phase 7)
    graph_db_bench/                ← R-MAT + Phase-1 read bench harness
  example/                        ← Flutter demo app (iOS / Android / desktop)
```

The split follows plan §12 — `graph_db_core` is the only package the
public API consumer needs for the read path; everything else is opt-in.

## Running

Each package is independent (no Dart workspace gate — plan §1's Dart 3.5+
floor):

```sh
cd packages/graph_db_core
dart pub get
dart analyze
dart test
```

## Key decisions already absorbed

From the spike phase (plan §0):
- **Read API** leads with the primitive range layer (Spike A).
- **PropValue is boundary-only** — storage core is raw typed columns.
- **Merge** is copy-first (Spike B).
- **CSR / index arrays are `Uint32List`** — keeps web reachable, halves
  topology memory, caps the graph at 2³² nodes/edges.
- **Property store**: per-key typed column + presence bitmap + `isNull`
  bitmap, strict type-lock with `db.dropPropertyColumn` as the escape
  hatch (§3.2 / §5).
- **Dependencies** pinned per plan §13 — `package:cbor` ^6.5.1 (with
  hand-rolled hot-shape encoders), `package:xxh3` ^1.2.0,
  `package:uuid` ^4.5.0.
