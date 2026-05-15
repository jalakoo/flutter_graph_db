# graph_db_core — example app

A small Flutter sample app that drives `graph_db_core` against the
hand-built `SocialGraph` fixture (12 people across 4 companies, with
`knows` / `worksAt` / `founded` edges and `name` / `age` / `title` /
`foundedYear` properties).

The app demonstrates every Phase-1 read API in real UI:

| Screen | Exercises |
|---|---|
| **People** | `labelScan` + raw string / int property accessors. FAB adds a Person; "..." menu resets to the fixture. |
| **Person detail** | Callback-style `forEachOutNeighbor` / `forEachInNeighbor` — both directions through the reverse CSR. Edit / delete the Person; add or remove `knows`-, `worksAt`-, and `founded`-edges. |
| **Companies** | Reverse-CSR traversal — "who works at this company" via in-edges. FAB adds a Company; tap a card to drill into the detail screen. |
| **Company detail** | Edit name / founded year; delete (cascades all incident `worksAt` / `founded` edges). Surfaces employees + founders through the reverse CSR. |
| **Graph** | Interactive node-link view (force-directed, pan + zoom) — nodes coloured by label, edges by type. Built on `package:graphview` with a thin `NonOverlapFruchtermanReingoldAlgorithm` subclass that runs an AABB-separation pass after the base FR converges — **no two node rects overlap**, guaranteed. **Recomputes layout when the user re-enters the tab and data has changed since the last visit** (re-keys the tab's `Navigator` against the repository's commit counter). Tapping a Person → Person detail; tapping a Company → Company detail. |
| **Stats** | Whole-graph degree scan in a tight loop over the primitive range API. |

All reads are allocation-free on the hot path (plan §3.2, Spike A) — the
top-level `GraphDb` facade keeps the primitive `(start, end, indexed
access)` shape available alongside the callback sugar.

## Persistence + reset

Mutations (add / edit / delete / `knows`) survive an app restart. The
`GraphRepository` writes a JSON snapshot to the app documents directory
after every commit, and reads it back on launch. The "Reset to fixture"
action under the People-tab overflow menu deletes the snapshot and
re-seeds from the hand-built `SocialGraph` fixture.

The JSON layer is **example-only** — it stands in for the eventual
`graph_db_wal` package (plan §6, CBOR + WAL framing), which Phase 2 will
deliver. Production callers will switch to a WAL-backed
`GraphDb.open(path: ...)` once that ships.

## Run

```sh
cd flutter_graph_db/example
flutter pub get
flutter run                                 # default device
flutter run -d ios --release                # iPhone release build
```

## Tests

Widget tests:

```sh
flutter test
```

On-device integration test (release-mode AOT — the verdict run):

```sh
flutter test integration_test/example_app_test.dart -d <iphone>
```

## Layout

```
lib/
  main.dart                    # builds the fixture, runs `ExampleApp`
  src/
    app.dart                   # MaterialApp + bottom-nav shell
    db_scope.dart              # InheritedWidget exposing the GraphDb
    data/
      engine_view.dart           # typed read view rebuilt per commit
      graph_data.dart            # JSON-serialisable source of truth
    repository/
      graph_repository.dart      # ChangeNotifier + persistence + reset
    dialogs/
      person_form_dialog.dart    # add / edit Person
      company_form_dialog.dart   # add / edit Company
      add_connection_dialog.dart # multi-select knows-connections
      pick_company_dialog.dart   # single-select Company picker
    graph_layout/
      non_overlap_algorithm.dart # FR + AABB-separation post-pass
    screens/
      people_screen.dart
      person_detail_screen.dart
      companies_screen.dart
      company_detail_screen.dart
      graph_screen.dart
      stats_screen.dart
    widgets/
      labelled_chip.dart
test/widget_test.dart
integration_test/example_app_test.dart
```

The structure follows the conventions from
[flutter/samples](https://github.com/flutter/samples): Material 3 theme,
a top-level shell with `NavigationBar` + per-tab `Navigator`, a single
inherited scope for the shared engine handle, and one widget per file
under `lib/src/`.
