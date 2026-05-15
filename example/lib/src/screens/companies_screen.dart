import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import '../widgets/labelled_chip.dart';

/// Companies + their employees. Demonstrates `inDegree` and reverse-CSR
/// traversal (`forEachInNeighbor`) — the always-built reverse CSR is what
/// keeps "first incoming query" cheap (plan §3.1).
class CompaniesScreen extends StatelessWidget {
  const CompaniesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sg = DbScope.of(context);
    final db = sg.db;
    final companies = db.labelScan(sg.companyLabel);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Companies'),
        scrolledUnderElevation: 1,
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final raw in companies)
            _CompanyCard(vid: Vid(raw)),
        ],
      ),
    );
  }
}

class _CompanyCard extends StatelessWidget {
  final Vid vid;
  const _CompanyCard({required this.vid});

  @override
  Widget build(BuildContext context) {
    final sg = DbScope.of(context);
    final db = sg.db;
    final theme = Theme.of(context);

    final name = db.getNodeStringProp(vid, sg.nameKey);
    final founded = db.getNodeIntProp(vid, sg.foundedYearKey);

    // Employees + founders via reverse CSR.
    final employees = <Vid>[];
    final founders = <Vid>[];
    db.forEachInNeighbor(vid, (src, eid, t) {
      if (t == sg.worksAtEdge) {
        employees.add(src);
      } else if (t == sg.foundedEdge) {
        founders.add(src);
      }
    });

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
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
                    value: db.getNodeStringProp(founders.first, sg.nameKey),
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
                    Chip(label: Text(db.getNodeStringProp(v, sg.nameKey))),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
