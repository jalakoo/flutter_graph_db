import 'package:flutter/material.dart';
import 'package:flutter_graph_db_example/src/app.dart';
import 'package:flutter_graph_db_example/src/db_scope.dart';
import 'package:flutter_graph_db_example/src/repository/graph_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graph_db_core/graph_db_core.dart';

Widget _root(GraphRepository repo) =>
    DbScope(repository: repo, child: const ExampleApp());

void main() {
  testWidgets('app boots and lands on the People tab', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    expect(find.text('People'), findsWidgets);
    for (final name in const ['Alice', 'Dan', 'Niaj']) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('tapping a Person navigates to the detail screen',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();

    expect(find.text('Engineer'), findsWidgets);
    expect(find.text('Acme'), findsWidgets);
  });

  testWidgets('Companies tab lists the four companies', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
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

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.hub_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Person'), findsWidgets);
    expect(find.text('Company'), findsWidgets);
    expect(find.text('knows'), findsOneWidget);
    expect(find.text('worksAt'), findsOneWidget);
    expect(find.text('founded'), findsOneWidget);
    expect(find.text('A'), findsWidgets);
  });

  testWidgets('Stats tab reports the right node and edge counts',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.analytics_outlined));
    await tester.pumpAndSettle();

    expect(find.text('${repo.db.nodeCount}'), findsOneWidget);
    expect(find.text('${repo.db.edgeCount}'), findsOneWidget);
  });

  testWidgets('addPerson appends a Person and the UI reflects it',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    repo.addPerson(name: 'Quinn', age: 24, title: 'Tester');
    await tester.pumpAndSettle();

    expect(find.text('Quinn'), findsOneWidget);
    expect(repo.view.people.length, 13);
  });

  testWidgets('deleteNode removes the Person from the list', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    repo.deleteNode(const Vid(0)); // Alice
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('tapping a Company card opens the detail screen',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.apartment_outlined));
    await tester.pumpAndSettle();

    // Drill into Acme.
    await tester.tap(find.text('Acme').first);
    await tester.pumpAndSettle();

    // Detail screen header shows the founded year and the employees
    // section title with a non-zero count.
    expect(find.text('Founded 1947'), findsWidgets);
    expect(find.textContaining('Employees ('), findsOneWidget);
  });

  testWidgets('addCompany puts the new Company in the list', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.apartment_outlined));
    await tester.pumpAndSettle();

    repo.addCompany(name: 'Soylent', foundedYear: 2013);
    await tester.pumpAndSettle();
    expect(find.text('Soylent'), findsOneWidget);
  });

  testWidgets('setWorksAt updates the Person detail screen', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    // Drill into Alice; she works at Acme in the fixture.
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    expect(find.text('Acme'), findsWidgets);

    // Reassign her to Globex programmatically and confirm the UI updates.
    repo.setWorksAt(const Vid(0), const Vid(13)); // Globex
    await tester.pumpAndSettle();
    expect(find.text('Globex'), findsWidgets);
  });

  testWidgets('addFounded then removeFounded round-trip', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    // Bob founds Initech.
    repo.addFounded(const Vid(1), const Vid(14));
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(find.text('Founded (1)'), findsOneWidget);
    expect(find.text('Initech'), findsWidgets);

    // Remove and confirm count drops back to 0.
    repo.removeFounded(const Vid(1), const Vid(14));
    await tester.pumpAndSettle();
    expect(find.text('Founded (0)'), findsOneWidget);
  });

  testWidgets('commitCount bumps on every mutation and on reset',
      (tester) async {
    final repo = GraphRepository.inMemory();
    final start = repo.commitCount;
    repo.addPerson(name: 'X', age: 1, title: 'Y');
    expect(repo.commitCount, start + 1);
    repo.editPerson(const Vid(0), name: 'NewAlice');
    expect(repo.commitCount, start + 2);
    repo.deleteNode(const Vid(1));
    expect(repo.commitCount, start + 3);
    await repo.reset();
    expect(repo.commitCount, start + 4);
  });

  testWidgets('reset reloads the fixture', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = GraphRepository.inMemory();
    await tester.pumpWidget(_root(repo));
    await tester.pumpAndSettle();

    repo.deleteNode(const Vid(0));
    repo.addPerson(name: 'Quinn', age: 24, title: 'Tester');
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsNothing);
    expect(find.text('Quinn'), findsOneWidget);

    await repo.reset();
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Quinn'), findsNothing);
  });
}
