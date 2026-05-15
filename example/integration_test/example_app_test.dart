import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_graph_db_example/src/app.dart';
import 'package:flutter_graph_db_example/src/db_scope.dart';
import 'package:flutter_graph_db_example/src/repository/graph_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device integration test for the example app.
///
/// Run:
/// `flutter test integration_test/example_app_test.dart -d DEVICE_ID`
///
/// On a release-mode AOT build this is what proves the package is
/// usable from a real Flutter app on a phone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('example app boots and exercises all four tabs',
      (tester) async {
    final platform = Platform.isIOS
        ? 'iOS'
        : Platform.isAndroid
            ? 'Android'
            : Platform.operatingSystem;
    debugPrint('graph_db_core example on $platform');

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(
      DbScope(repository: repo, child: const ExampleApp()),
    );
    await tester.pumpAndSettle();

    // People tab — Alice is in the list.
    expect(find.text('Alice'), findsOneWidget);

    // Drill into Alice's detail and back out.
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    expect(find.text('Acme'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Companies tab.
    await tester.tap(find.byIcon(Icons.apartment_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Acme'), findsWidgets);

    // Graph tab — force-directed layout + legend visible.
    await tester.tap(find.byIcon(Icons.hub_outlined));
    await tester.pumpAndSettle();
    expect(find.text('knows'), findsOneWidget);
    expect(find.text('worksAt'), findsOneWidget);

    // Stats tab — node + edge counts match the fixture.
    await tester.tap(find.byIcon(Icons.analytics_outlined));
    await tester.pumpAndSettle();
    expect(find.text('${repo.db.nodeCount}'), findsOneWidget);
    expect(find.text('${repo.db.edgeCount}'), findsOneWidget);
  });
}
