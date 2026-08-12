import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import '../dialogs/person_form_dialog.dart';
import 'person_detail_screen.dart';

/// Lists every (non-deleted) Person in the graph. Demonstrates
/// [GraphDb.labelScan] + raw property accessors, plus the add/reset
/// mutation flows.
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key});

  Future<void> _addPerson(BuildContext context) async {
    final result = await PersonFormDialog.show(
      context,
      title: 'Add Person',
    );
    if (result == null || !context.mounted) return;
    DbScope.repositoryOf(context).addPerson(
      name: result.name,
      age: result.age,
      title: result.title,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Added ${result.name}')));
  }

  Future<void> _confirmReset(BuildContext context) async {
    final repo = DbScope.repositoryOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to fixture?'),
        content: const Text(
          'Discards all add/edit/delete changes and reloads the original '
          'social-graph fixture. The persisted snapshot is deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repo.reset();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Reset complete')));
  }

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final personVids = view.people;

    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        scrolledUnderElevation: 1,
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (key) {
              if (key == 'reset') _confirmReset(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'reset',
                child: ListTile(
                  leading: Icon(Icons.restore),
                  title: Text('Reset to fixture'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addPerson(context),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add'),
      ),
      body: ListView.separated(
        itemCount: personVids.length,
        // Named rather than two `_`s: wildcard variables need language
        // version 3.7, and this app targets the repo-wide 3.6 floor.
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final vid = personVids[i];
          final name = db.getNodeStringProp(vid, view.nameKey);
          final title = db.getNodeStringProp(vid, view.titleKey);
          final age = db.getNodeIntProp(vid, view.ageKey);
          return ListTile(
            leading: CircleAvatar(child: Text(name.characters.first)),
            title: Text(name),
            subtitle: Text('$title · age $age'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PersonDetailScreen(vid: vid),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
