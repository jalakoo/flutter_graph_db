import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../data/engine_view.dart';

/// Multi-select picker for adding new `knows` connections from a given
/// person. Already-connected people and the source person itself are
/// excluded from the list.
class AddConnectionDialog extends StatefulWidget {
  final EngineView view;
  final Vid source;
  final Set<int> existingKnows; // dst vid values already connected

  const AddConnectionDialog({
    super.key,
    required this.view,
    required this.source,
    required this.existingKnows,
  });

  /// Returns the selected vids, or null if cancelled.
  static Future<List<Vid>?> show(
    BuildContext context, {
    required EngineView view,
    required Vid source,
    required Set<int> existingKnows,
  }) =>
      showDialog<List<Vid>>(
        context: context,
        builder: (_) => AddConnectionDialog(
          view: view,
          source: source,
          existingKnows: existingKnows,
        ),
      );

  @override
  State<AddConnectionDialog> createState() => _AddConnectionDialogState();
}

class _AddConnectionDialogState extends State<AddConnectionDialog> {
  final _selected = <int>{};

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final db = v.db;
    final candidates = v.people
        .where((vid) =>
            vid.value != widget.source.value &&
            !widget.existingKnows.contains(vid.value))
        .toList();

    return AlertDialog(
      title: const Text('Add knows-connection'),
      content: SizedBox(
        width: 380,
        height: 400,
        child: candidates.isEmpty
            ? const Center(child: Text('No one left to connect.'))
            : ListView.builder(
                itemCount: candidates.length,
                itemBuilder: (context, i) {
                  final vid = candidates[i];
                  final name = db.getNodeStringProp(vid, v.nameKey);
                  final title = db.getNodeStringProp(vid, v.titleKey);
                  final selected = _selected.contains(vid.value);
                  return CheckboxListTile(
                    value: selected,
                    title: Text(name),
                    subtitle: Text(title),
                    onChanged: (_) {
                      setState(() {
                        if (selected) {
                          _selected.remove(vid.value);
                        } else {
                          _selected.add(vid.value);
                        }
                      });
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                    _selected.map(Vid.new).toList(),
                  ),
          child: Text('Add (${_selected.length})'),
        ),
      ],
    );
  }
}
