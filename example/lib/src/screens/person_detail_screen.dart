import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import '../widgets/labelled_chip.dart';

/// Detail page for one Person. Demonstrates the **callback-style**
/// traversal sugar (`forEachOutNeighbor` / `forEachInNeighbor`) on top
/// of the primitive range API.
class PersonDetailScreen extends StatelessWidget {
  final Vid vid;
  const PersonDetailScreen({super.key, required this.vid});

  @override
  Widget build(BuildContext context) {
    final sg = DbScope.of(context);
    final db = sg.db;
    final theme = Theme.of(context);

    final name = db.getNodeStringProp(vid, sg.nameKey);
    final title = db.getNodeStringProp(vid, sg.titleKey);
    final age = db.getNodeIntProp(vid, sg.ageKey);

    // Walk the out-edges once, sort destinations by edge type.
    final knows = <Vid>[];
    final worksAt = <Vid>[];
    final founded = <Vid>[];
    db.forEachOutNeighbor(vid, (dst, eid, t) {
      if (t == sg.knowsEdge) {
        knows.add(dst);
      } else if (t == sg.worksAtEdge) {
        worksAt.add(dst);
      } else if (t == sg.foundedEdge) {
        founded.add(dst);
      }
    });
    // In-edges: who else `knows` this person.
    final knownBy = <Vid>[];
    db.forEachInNeighbor(vid, (src, eid, t) {
      if (t == sg.knowsEdge) knownBy.add(src);
    });

    return Scaffold(
      appBar: AppBar(title: Text(name)),
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
          _NodeSection(
            title: 'Works at',
            icon: Icons.apartment,
            ids: worksAt,
            empty: 'Not employed',
            propKey: sg.nameKey,
          ),
          _NodeSection(
            title: 'Founded',
            icon: Icons.flag,
            ids: founded,
            empty: '—',
            propKey: sg.nameKey,
          ),
          _NodeSection(
            title: 'Knows (${knows.length})',
            icon: Icons.connect_without_contact,
            ids: knows,
            empty: 'No connections',
            propKey: sg.nameKey,
          ),
          _NodeSection(
            title: 'Known by (${knownBy.length})',
            icon: Icons.alternate_email,
            ids: knownBy,
            empty: 'No incoming connections',
            propKey: sg.nameKey,
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
    final sg = DbScope.of(context);
    final db = sg.db;
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
