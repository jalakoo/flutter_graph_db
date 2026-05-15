import 'package:flutter/material.dart';
import 'package:flutter_graph_db_example/src/app.dart';
import 'package:flutter_graph_db_example/src/db_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graph_db_core/samples.dart';

void main() {
  testWidgets('app boots and lands on the People tab', (tester) async {
    // A tall viewport so every ListView/Card row in the fixture renders
    // without scrolling — keeps the assertions straightforward.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final social = SocialGraph.build();
    await tester.pumpWidget(
      DbScope(social: social, child: const ExampleApp()),
    );
    await tester.pumpAndSettle();

    // App bar of the People tab is visible.
    expect(find.text('People'), findsWidgets);

    // All twelve fixture names render somewhere in the People list.
    for (final name in const ['Alice', 'Dan', 'Niaj']) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('tapping a Person navigates to the detail screen',
      (tester) async {
    // A tall viewport so every ListView/Card row in the fixture renders
    // without scrolling — keeps the assertions straightforward.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final social = SocialGraph.build();
    await tester.pumpWidget(
      DbScope(social: social, child: const ExampleApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();

    // Detail screen renders Alice's title and her outgoing connections.
    expect(find.text('Engineer'), findsWidgets);
    expect(find.text('Acme'), findsWidgets);
  });

  testWidgets('Companies tab lists the four companies', (tester) async {
    // A tall viewport so every ListView/Card row in the fixture renders
    // without scrolling — keeps the assertions straightforward.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final social = SocialGraph.build();
    await tester.pumpWidget(
      DbScope(social: social, child: const ExampleApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.apartment_outlined));
    await tester.pumpAndSettle();

    for (final name in const ['Acme', 'Globex', 'Initech', 'Umbrella']) {
      expect(find.text(name), findsWidgets);
    }
  });

  testWidgets('Graph tab renders the legend and at least one node',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final social = SocialGraph.build();
    await tester.pumpWidget(
      DbScope(social: social, child: const ExampleApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.hub_outlined));
    await tester.pumpAndSettle();

    // Legend entries.
    expect(find.text('Person'), findsWidgets);
    expect(find.text('Company'), findsWidgets);
    expect(find.text('knows'), findsOneWidget);
    expect(find.text('worksAt'), findsOneWidget);
    expect(find.text('founded'), findsOneWidget);

    // At least the avatar text for Alice's node is laid out.
    expect(find.text('A'), findsWidgets);
  });

  testWidgets('Stats tab reports the right node and edge counts',
      (tester) async {
    // A tall viewport so every ListView/Card row in the fixture renders
    // without scrolling — keeps the assertions straightforward.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final social = SocialGraph.build();
    await tester.pumpWidget(
      DbScope(social: social, child: const ExampleApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.analytics_outlined));
    await tester.pumpAndSettle();

    expect(find.text('${social.db.nodeCount}'), findsOneWidget);
    expect(find.text('${social.db.edgeCount}'), findsOneWidget);
  });
}
