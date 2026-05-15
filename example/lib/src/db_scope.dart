import 'package:flutter/widgets.dart';
import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_core/samples.dart';

/// Inherited widget exposing the [SocialGraph] (and the [GraphDb] inside
/// it) to the widget tree. The fixture is built once in `main` and
/// stays constant for the lifetime of the app, so plain
/// [InheritedWidget] is enough — no notifier needed.
class DbScope extends InheritedWidget {
  final SocialGraph social;

  const DbScope({
    super.key,
    required this.social,
    required super.child,
  });

  GraphDb get db => social.db;

  static SocialGraph of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DbScope>();
    assert(scope != null, 'DbScope.of called outside the DbScope subtree');
    return scope!.social;
  }

  @override
  bool updateShouldNotify(DbScope oldWidget) =>
      !identical(oldWidget.social, social);
}
