import 'package:flutter/material.dart';
import 'package:graph_db_core/samples.dart';

import 'src/app.dart';
import 'src/db_scope.dart';

void main() {
  // Phase 1: the graph is built synchronously from a hand-written
  // fixture. Future phases load it from a WAL on disk, in which case
  // this is where the `await GraphDb.open(...)` happens behind a
  // splash / loading state.
  final social = SocialGraph.build();
  runApp(DbScope(social: social, child: const ExampleApp()));
}
