# flutter_graph_db — example app

A small Flutter sample app that drives the embedded graph DB against a
hand-built `SocialGraph` fixture (12 people across 4 companies, with
`knows` / `worksAt` / `founded` edges and `name` / `age` / `title` /
`foundedYear` properties).

The app doubles as a live demo and a copy-paste reference for the
public API — every screen exercises a different read pattern, the
Stats tab includes an on-device perf bench, and the persistence layer
plugs into the real `graph_db_wal` package.

## Contents

- [What the screens demonstrate](#what-the-screens-demonstrate)
- [Use this package in your own app](#use-this-package-in-your-own-app)
- [In-app perf bench](#in-app-perf-bench)
- [Persistence + reset](#persistence--reset)
- [Run](#run)
- [Tests](#tests)
- [Layout](#layout)

## What the screens demonstrate

All reads are allocation-free on the hot path — the top-level
`GraphDb` façade keeps the primitive `(start, end, indexed-access)`
shape available alongside the callback sugar.

| Screen | Exercises |
|---|---|
| **People** | `labelScan` + raw string / int property accessors. FAB adds a Person; "…" menu resets to the fixture. |
| **Person detail** | Callback-style `forEachOutNeighbor` / `forEachInNeighbor` — both directions through the reverse CSR. Edit / delete the Person; add or remove `knows` / `worksAt` / `founded` edges. |
| **Companies** | Reverse-CSR traversal — "who works at this company" via in-edges. FAB adds a Company; tap a card to drill into the detail screen. |
| **Company detail** | Edit name / founded year; delete (cascades all incident `worksAt` / `founded` edges). Surfaces employees + founders through the reverse CSR. |
| **Graph** | Interactive node-link view (force-directed, pan + zoom) — nodes coloured by label, edges by type. Built on `package:graphview` with a thin `NonOverlapFruchtermanReingoldAlgorithm` subclass that runs an AABB-separation pass after the base FR converges — **no two node rects overlap**, guaranteed. **Recomputes layout when the user re-enters the tab and data has changed since the last visit** (re-keys the tab's `Navigator` against the repository's commit counter). Tapping a Person → Person detail; tapping a Company → Company detail. |
| **Stats** | Whole-graph degree scan in a tight loop over the primitive range API. **Includes the [in-app perf bench](#in-app-perf-bench)** — pick an N, tap Run, copy the device-tagged result line to the clipboard. |

## Use this package in your own app

This is an example — to drop the engine into your own app, depend on
the umbrella package (`flutter_graph_db`) rather than this example
dir.

The
[`flutter_graph_db` package README](../packages/flutter_graph_db/README.md)
is the authoritative consumer guide — it walks through install
(git / path), the in-memory quickstart, web + mobile + desktop
persistence wiring, the snapshot + compact cycle, the read-your-writes
lifecycle, and the sub-package map.

A consumer-perspective smoke test under
`/tmp/flutter_graph_db_smoke/` (built during this app's bring-up)
exercises every documented entry point in ~100 lines and is the
shortest possible "I just want to use this from another app" starting
template.

## In-app perf bench

The Stats tab carries a `PerfBench` widget that runs N node inserts
against a fresh temp `GraphDb`, then merge, then N×10 reads. Reports
total / p50 / p99 / throughput + merge stall with per-platform tagging
+ one-tap clipboard copy.

The widget lives at `lib/src/widgets/perf_bench.dart` — ~250 lines,
self-contained, depends only on `flutter/material` +
`graph_db_core`. Copy it into your own app and drop
`const PerfBench()` into any debug page.

For non-Flutter measurement runs (CLI, repeatable, profile-against-
remote-backend), use the
[`graph_db_bench`](../packages/graph_db_bench) package — see the
[umbrella README's Benchmarking section](../packages/flutter_graph_db/README.md#benchmarking).

## Persistence + reset

Mutations (add / edit / delete / `knows` / `worksAt` / `founded`)
survive an app restart. The `GraphRepository` writes a JSON snapshot
to the app documents directory after every commit, and reads it back
on launch. The "Reset to fixture" action under the People-tab overflow
menu deletes the snapshot and re-seeds from the hand-built
`SocialGraph` fixture.

The JSON layer is **example-only** — it stands in for the
`graph_db_wal` package's CBOR + WAL framing, which is what a
production caller should plug into instead. The
[umbrella README](../packages/flutter_graph_db/README.md) walks
through the WAL-backed open + snapshot + compact cycle.

## Run

```sh
cd flutter_graph_db/example
flutter pub get
flutter run                              # default device
flutter run -d chrome --profile          # web, profile mode (for Perf bench)
flutter run -d <iphone> --release        # iPhone release build
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
      stats_screen.dart          # includes the Perf bench card
    widgets/
      labelled_chip.dart
      perf_bench.dart            # in-app perf measurement widget
test/widget_test.dart
integration_test/example_app_test.dart
```

The structure follows the conventions from
[flutter/samples](https://github.com/flutter/samples): Material 3
theme, a top-level shell with `NavigationBar` + per-tab `Navigator`, a
single inherited scope for the shared engine handle, and one widget
per file under `lib/src/`.
