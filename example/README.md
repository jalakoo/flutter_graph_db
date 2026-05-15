# graph_db_core — example app

A small Flutter sample app that drives `graph_db_core` against the
hand-built `SocialGraph` fixture (12 people across 4 companies, with
`knows` / `worksAt` / `founded` edges and `name` / `age` / `title` /
`foundedYear` properties).

The app demonstrates every Phase-1 read API in real UI:

| Screen | Exercises |
|---|---|
| **People** | `labelScan` + raw string / int property accessors. |
| **Person detail** | Callback-style `forEachOutNeighbor` / `forEachInNeighbor` — both directions through the reverse CSR. |
| **Companies** | Reverse-CSR traversal — "who works at this company" via in-edges. |
| **Graph** | Interactive node-link view (force-directed, pan + zoom) — nodes coloured by label, edges by type. Built on `package:graphview`. |
| **Stats** | Whole-graph degree scan in a tight loop over the primitive range API. |

All reads are allocation-free on the hot path (plan §3.2, Spike A) — the
top-level `GraphDb` facade keeps the primitive `(start, end, indexed
access)` shape available alongside the callback sugar.

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
    screens/
      people_screen.dart
      person_detail_screen.dart
      companies_screen.dart
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
