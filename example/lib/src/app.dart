import 'package:flutter/material.dart';

import 'db_scope.dart';
import 'screens/companies_screen.dart';
import 'screens/graph_screen.dart';
import 'screens/people_screen.dart';
import 'screens/stats_screen.dart';

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'graph_db_core — example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A6FA5),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A6FA5),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

/// Top-level shell hosting a bottom navigation bar. The four tabs each
/// own a `Navigator` so detail pushes stay within the active tab.
///
/// **Graph tab refresh.** The force-directed layout is deliberately *not*
/// recomputed on every mutation — that would shuffle node positions out
/// from under the user. Instead, when the user **enters** the Graph tab
/// from another tab and the data has changed since their last visit, we
/// re-key the Graph tab's `_TabNavigator` so [GraphScreen] is recreated
/// with a fresh layout.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const int _graphIndex = 2;

  int _index = 0;
  int _graphGen = 0;
  int _lastSeenCommit = -1; // forces a fresh build on the first visit

  static const _destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.people_outline),
      selectedIcon: Icon(Icons.people),
      label: 'People',
    ),
    NavigationDestination(
      icon: Icon(Icons.apartment_outlined),
      selectedIcon: Icon(Icons.apartment),
      label: 'Companies',
    ),
    NavigationDestination(
      icon: Icon(Icons.hub_outlined),
      selectedIcon: Icon(Icons.hub),
      label: 'Graph',
    ),
    NavigationDestination(
      icon: Icon(Icons.analytics_outlined),
      selectedIcon: Icon(Icons.analytics),
      label: 'Stats',
    ),
  ];

  void _onSelected(int i) {
    setState(() {
      if (i == _graphIndex && _index != _graphIndex) {
        // Read the current commit count without registering a build
        // dependency — we only want to re-key on tab-entry, not on
        // every mutation.
        final scope = context.findAncestorWidgetOfExactType<DbScope>();
        final gen = scope?.repository.commitCount ?? 0;
        if (gen != _lastSeenCommit) {
          _graphGen++;
          _lastSeenCommit = gen;
        }
      }
      _index = i;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const _TabNavigator(child: PeopleScreen()),
          const _TabNavigator(child: CompaniesScreen()),
          _TabNavigator(
            key: ValueKey('graph-$_graphGen'),
            child: const GraphScreen(),
          ),
          const _TabNavigator(child: StatsScreen()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        destinations: _destinations,
        selectedIndex: _index,
        onDestinationSelected: _onSelected,
      ),
    );
  }
}

class _TabNavigator extends StatelessWidget {
  final Widget child;
  const _TabNavigator({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (settings) =>
          MaterialPageRoute(builder: (_) => child, settings: settings),
    );
  }
}
