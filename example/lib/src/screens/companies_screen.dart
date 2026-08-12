import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import '../dialogs/company_form_dialog.dart';
import '../widgets/labelled_chip.dart';
import 'company_detail_screen.dart';

/// Companies + their employees. Tap a card to drill in;
/// floating-action-button adds a new Company.
class CompaniesScreen extends StatelessWidget {
  const CompaniesScreen({super.key});

  Future<void> _addCompany(BuildContext context) async {
    final result = await CompanyFormDialog.show(
      context,
      title: 'Add Company',
    );
    if (result == null || !context.mounted) return;
    DbScope.repositoryOf(context).addCompany(
      name: result.name,
      foundedYear: result.foundedYear,
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Added ${result.name}')));
  }

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final companies = view.companies;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Companies'),
        scrolledUnderElevation: 1,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCompany(context),
        icon: const Icon(Icons.add_business),
        label: const Text('Add'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [for (final vid in companies) _CompanyCard(vid: vid)],
      ),
    );
  }
}

class _CompanyCard extends StatelessWidget {
  final Vid vid;
  const _CompanyCard({required this.vid});

  @override
  Widget build(BuildContext context) {
    final view = DbScope.of(context);
    final db = view.db;
    final theme = Theme.of(context);

    final name = db.getNodeStringProp(vid, view.nameKey);
    final founded = db.getNodeIntProp(vid, view.foundedYearKey);

    final employees = <Vid>[];
    final founders = <Vid>[];
    db.forEachInNeighbor(vid, (src, eid, t) {
      if (t == view.worksAtEdge) {
        employees.add(src);
      } else if (t == view.foundedEdge) {
        founders.add(src);
      }
    });

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => CompanyDetailScreen(vid: vid)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.apartment, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(name, style: theme.textTheme.titleLarge),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  LabelledChip(
                    label: 'founded',
                    value: '$founded',
                    icon: Icons.event,
                  ),
                  LabelledChip(
                    label: 'employees',
                    value: '${employees.length}',
                    icon: Icons.groups,
                  ),
                  if (founders.isNotEmpty)
                    LabelledChip(
                      label: 'founder',
                      value: db.getNodeStringProp(
                          founders.first, view.nameKey),
                      icon: Icons.flag,
                    ),
                ],
              ),
              if (employees.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final v in employees)
                      Chip(
                          label:
                              Text(db.getNodeStringProp(v, view.nameKey))),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
