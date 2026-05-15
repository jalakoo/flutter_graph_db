import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../data/engine_view.dart';

/// Single-select picker over the current set of Companies. Used by the
/// Person detail screen to set `worksAt` or add a `founded` edge.
class PickCompanyDialog extends StatelessWidget {
  final EngineView view;
  final String title;

  /// Vids to exclude from the list (e.g. already-founded companies, or
  /// the current `worksAt` target). May be empty.
  final Set<int> exclude;

  /// Whether to show the "None" option that returns [Vid.invalid]. Used
  /// by `setWorksAt` to remove the existing edge.
  final bool allowNone;

  const PickCompanyDialog({
    super.key,
    required this.view,
    required this.title,
    this.exclude = const {},
    this.allowNone = false,
  });

  /// Returns the picked Vid, or `Vid.invalid` if the user picked "None",
  /// or `null` if the dialog was cancelled.
  static Future<Vid?> show(
    BuildContext context, {
    required EngineView view,
    required String title,
    Set<int> exclude = const {},
    bool allowNone = false,
  }) =>
      showDialog<Vid>(
        context: context,
        builder: (_) => PickCompanyDialog(
          view: view,
          title: title,
          exclude: exclude,
          allowNone: allowNone,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final db = view.db;
    final candidates = view.companies
        .where((vid) => !exclude.contains(vid.value))
        .toList();

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        height: 360,
        child: candidates.isEmpty && !allowNone
            ? const Center(child: Text('No companies available.'))
            : ListView(
                children: [
                  if (allowNone)
                    ListTile(
                      leading: const Icon(Icons.clear),
                      title: const Text('None'),
                      onTap: () => Navigator.of(context).pop(Vid.invalid),
                    ),
                  for (final vid in candidates)
                    ListTile(
                      leading: const Icon(Icons.apartment),
                      title: Text(db.getNodeStringProp(vid, view.nameKey)),
                      subtitle: Text(
                          'Founded ${db.getNodeIntProp(vid, view.foundedYearKey)}'),
                      onTap: () => Navigator.of(context).pop(vid),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
