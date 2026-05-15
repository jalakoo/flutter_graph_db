import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/db_scope.dart';
import 'src/repository/graph_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Read the persisted snapshot if there is one; otherwise seed from
  // the social-graph fixture. Async because path_provider hits the
  // platform channel to resolve the documents directory.
  final repo = await GraphRepository.open();
  runApp(DbScope(repository: repo, child: const ExampleApp()));
}
