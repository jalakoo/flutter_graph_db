import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import '../dialogs/company_form_dialog.dart';
import '../widgets/labelled_chip.dart';

/// Detail page for one Company — mirrors [PersonDetailScreen] but
/// surfaces employees + founders via the reverse CSR.
class CompanyDetailScreen extends StatelessWidget {
  final Vid vid;
  const CompanyDetailScreen({super.key, required this.vid});

  Future<void> _edit(BuildContext context) async {
    final view = DbScope.of(context);
    final db = view.db;
    final result = await CompanyFormDialog.show(
      context,
      title: 'Edit Company',
      initial: CompanyFormResult(
        name: db.getNodeStringProp(vid, view.nameKey),
        foundedYear: db.getNodeIntProp(vid, view.foundedYearKey),
      ),
    );
    if (result == null || !context.mounted) return;
    DbScope.repositoryOf(context).editCompany(
      vid,
      name: result.name,
      foundedYear: result.foundedYear,
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
          'Tombstones the company and cascade-deletes every worksAt and '
          'founded edge that touches it. The vid is never reused.',
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

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final theme = Theme.of(context);

    final name = db.getNodeStringProp(vid, view.nameKey);
    final foundedYear = db.getNodeIntProp(vid, view.foundedYearKey);

    final employees = <Vid>[];
    final founders = <Vid>[];
    db.forEachInNeighbor(vid, (src, eid, t) {
      if (t == view.worksAtEdge) {
        employees.add(src);
      } else if (t == view.foundedEdge) {
        founders.add(src);
      }
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
                backgroundColor: theme.colorScheme.tertiaryContainer,
                foregroundColor: theme.colorScheme.onTertiaryContainer,
                child: const Icon(Icons.apartment),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text('Founded $foundedYear',
                        style: theme.textTheme.bodyMedium),
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
              LabelledChip(
                  label: 'founded', value: '$foundedYear', icon: Icons.event),
              LabelledChip(label: 'vid', value: '${vid.value}'),
              LabelledChip(label: 'label', value: 'Company'),
            ],
          ),
          const SizedBox(height: 24),
          _ReadonlyNodeSection(
            title: 'Employees (${employees.length})',
            icon: Icons.groups,
            ids: employees,
            empty: 'No employees',
            propKey: view.nameKey,
          ),
          _ReadonlyNodeSection(
            title: 'Founders (${founders.length})',
            icon: Icons.flag,
            ids: founders,
            empty: 'No founders recorded',
            propKey: view.nameKey,
          ),
        ],
      ),
    );
  }
}

class _ReadonlyNodeSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Vid> ids;
  final String empty;
  final int propKey;

  const _ReadonlyNodeSection({
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
