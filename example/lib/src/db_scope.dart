import 'package:flutter/widgets.dart';

import 'data/engine_view.dart';
import 'repository/graph_repository.dart';

/// Inherited notifier exposing the [GraphRepository] (and the live
/// [EngineView] / [GraphDb] inside it) to the widget tree. Every
/// mutation calls `notifyListeners()` on the repo, which propagates
/// through here to dependent widgets.
class DbScope extends InheritedNotifier<GraphRepository> {
  const DbScope({
    super.key,
    required GraphRepository repository,
    required super.child,
  }) : super(notifier: repository);

  GraphRepository get repository => notifier!;

  /// Read-side handle for screens that only display data. Subscribing
  /// to this rebuilds the calling widget when the repository commits.
  static EngineView of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DbScope>();
    assert(scope != null, 'DbScope.of called outside the DbScope subtree');
    return scope!.repository.view;
  }

  /// Mutation-side handle. Subscribes the calling widget too (Flutter's
  /// pattern: any code path that depends on the inherited widget should
  /// participate in the dependency, so a stale handle never lingers).
  static GraphRepository repositoryOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DbScope>();
    assert(scope != null, 'DbScope.repositoryOf called outside DbScope');
    return scope!.repository;
  }
}
