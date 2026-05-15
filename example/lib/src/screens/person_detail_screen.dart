import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import '../dialogs/add_connection_dialog.dart';
import '../dialogs/person_form_dialog.dart';
import '../dialogs/pick_company_dialog.dart';
import '../widgets/labelled_chip.dart';

/// Detail page for one Person. Read demonstrates **callback-style**
/// traversal (`forEachOutNeighbor` / `forEachInNeighbor`); write
/// demonstrates edit, delete, and `knows`-edge management.
class PersonDetailScreen extends StatelessWidget {
  final Vid vid;
  const PersonDetailScreen({super.key, required this.vid});

  Future<void> _edit(BuildContext context) async {
    final view = DbScope.of(context);
    final db = view.db;
    final initial = PersonFormResult(
      name: db.getNodeStringProp(vid, view.nameKey),
      age: db.getNodeIntProp(vid, view.ageKey),
      title: db.getNodeStringProp(vid, view.titleKey),
    );
    final result = await PersonFormDialog.show(
      context,
      title: 'Edit Person',
      initial: initial,
    );
    if (result == null || !context.mounted) return;
    DbScope.repositoryOf(context).editPerson(
      vid,
      name: result.name,
      age: result.age,
      title: result.title,
    );
  }

  Future<void> _delete(BuildContext context) async {
    final view = DbScope.of(context);
    final db = view.db;
    final name = db.getNodeStringProp(vid, view.nameKey);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
          'Tombstones the node and cascade-deletes all incident edges. '
          'The vid is never reused.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
              foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    DbScope.repositoryOf(context).deleteNode(vid);
    if (!context.mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _addConnections(BuildContext context) async {
    final view = DbScope.of(context);
    final db = view.db;
    final existing = <int>{};
    db.forEachOutNeighbor(vid, (dst, eid, t) {
      if (t == view.knowsEdge) existing.add(dst.value);
    });
    final picked = await AddConnectionDialog.show(
      context,
      view: view,
      source: vid,
      existingKnows: existing,
    );
    if (picked == null || picked.isEmpty || !context.mounted) return;
    final repo = DbScope.repositoryOf(context);
    for (final p in picked) {
      repo.addKnows(vid, p);
    }
  }

  Future<void> _editWorksAt(BuildContext context, Vid? current) async {
    final view = DbScope.of(context);
    final picked = await PickCompanyDialog.show(
      context,
      view: view,
      title: 'Works at',
      // Don't offer the company they already work at, but do offer "None".
      exclude: current == null ? const {} : {current.value},
      allowNone: current != null,
    );
    if (picked == null || !context.mounted) return;
    DbScope.repositoryOf(context)
        .setWorksAt(vid, picked.isValid ? picked : null);
  }

  Future<void> _addFounded(BuildContext context, List<Vid> existing) async {
    final view = DbScope.of(context);
    final picked = await PickCompanyDialog.show(
      context,
      view: view,
      title: 'Founded',
      exclude: existing.map((v) => v.value).toSet(),
    );
    if (picked == null || !picked.isValid || !context.mounted) return;
    DbScope.repositoryOf(context).addFounded(vid, picked);
  }

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final theme = Theme.of(context);

    final name = db.getNodeStringProp(vid, view.nameKey);
    final title = db.getNodeStringProp(vid, view.titleKey);
    final age = db.getNodeIntProp(vid, view.ageKey);

    // Walk the out-edges once, group by edge type.
    final knows = <Vid>[];
    final worksAt = <Vid>[];
    final founded = <Vid>[];
    db.forEachOutNeighbor(vid, (dst, eid, t) {
      if (t == view.knowsEdge) {
        knows.add(dst);
      } else if (t == view.worksAtEdge) {
        worksAt.add(dst);
      } else if (t == view.foundedEdge) {
        founded.add(dst);
      }
    });
    final knownBy = <Vid>[];
    db.forEachInNeighbor(vid, (src, eid, t) {
      if (t == view.knowsEdge) knownBy.add(src);
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _edit(context),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                child: Text(
                  name.characters.first,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(title, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              LabelledChip(label: 'age', value: '$age', icon: Icons.cake),
              LabelledChip(label: 'vid', value: '${vid.value}'),
              LabelledChip(label: 'label', value: 'Person'),
            ],
          ),
          const SizedBox(height: 24),
          _WorksAtSection(
            current: worksAt.isEmpty ? null : worksAt.first,
            onEdit: () =>
                _editWorksAt(context, worksAt.isEmpty ? null : worksAt.first),
          ),
          _FoundedSection(
            personVid: vid,
            ids: founded,
            onAdd: () => _addFounded(context, founded),
          ),
          _KnowsSection(
            sourceVid: vid,
            ids: knows,
            onAdd: () => _addConnections(context),
          ),
          _NodeSection(
            title: 'Known by (${knownBy.length})',
            icon: Icons.alternate_email,
            ids: knownBy,
            empty: 'No incoming connections',
            propKey: view.nameKey,
          ),
        ],
      ),
    );
  }
}

class _NodeSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Vid> ids;
  final String empty;
  final int propKey;

  const _NodeSection({
    required this.title,
    required this.icon,
    required this.ids,
    required this.empty,
    required this.propKey,
  });

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(title, style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 8),
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 12),
            child: Text(empty, style: theme.textTheme.bodySmall),
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in ids)
                  Chip(label: Text(db.getNodeStringProp(id, propKey))),
              ],
            ),
          ),
      ],
    );
  }
}

/// Single-valued `worksAt` section — chip displays the current company
/// with a tap-to-edit affordance; "Set" appears when no edge exists.
class _WorksAtSection extends StatelessWidget {
  final Vid? current;
  final VoidCallback onEdit;
  const _WorksAtSection({required this.current, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.apartment,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('Works at', style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              icon: Icon(current == null ? Icons.add : Icons.edit_outlined),
              label: Text(current == null ? 'Set' : 'Edit'),
              onPressed: onEdit,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 26, bottom: 16),
          child: current == null
              ? Text('Not employed', style: theme.textTheme.bodySmall)
              : Wrap(spacing: 8, children: [
                  Chip(label: Text(db.getNodeStringProp(current!, view.nameKey))),
                ]),
        ),
      ],
    );
  }
}

/// Multi-valued `founded` section — same shape as `_KnowsSection`.
class _FoundedSection extends StatelessWidget {
  final Vid personVid;
  final List<Vid> ids;
  final VoidCallback onAdd;
  const _FoundedSection({
    required this.personVid,
    required this.ids,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.flag, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('Founded (${ids.length})',
                style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add'),
              onPressed: onAdd,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 12),
            child: Text('—', style: theme.textTheme.bodySmall),
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in ids)
                  InputChip(
                    label: Text(db.getNodeStringProp(id, view.nameKey)),
                    onDeleted: () => DbScope.repositoryOf(context)
                        .removeFounded(personVid, id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Specialised section for `knows` connections — each chip carries a
/// delete affordance, and a trailing "Add" button opens the multi-select.
class _KnowsSection extends StatelessWidget {
  final Vid sourceVid;
  final List<Vid> ids;
  final VoidCallback onAdd;
  const _KnowsSection({
    required this.sourceVid,
    required this.ids,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.connect_without_contact,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('Knows (${ids.length})',
                style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add'),
              onPressed: onAdd,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 12),
            child:
                Text('No connections', style: theme.textTheme.bodySmall),
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 26, bottom: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in ids)
                  InputChip(
                    label: Text(db.getNodeStringProp(id, view.nameKey)),
                    onDeleted: () =>
                        DbScope.repositoryOf(context).removeKnows(sourceVid, id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
