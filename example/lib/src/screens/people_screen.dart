import 'package:flutter/material.dart';
import 'package:graph_db_core/graph_db_core.dart';

import '../db_scope.dart';
import 'person_detail_screen.dart';

/// Lists every Person in the graph. Demonstrates [GraphDb.labelScan] +
/// raw property accessors (no boxing on the hot path — plan §3.2).
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sg = DbScope.of(context);
    final db = sg.db;
    final personVids = db.labelScan(sg.personLabel);

    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
        scrolledUnderElevation: 1,
      ),
      body: ListView.separated(
        itemCount: personVids.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final vid = Vid(personVids[i]);
          final name = db.getNodeStringProp(vid, sg.nameKey);
          final title = db.getNodeStringProp(vid, sg.titleKey);
          final age = db.getNodeIntProp(vid, sg.ageKey);
          return ListTile(
            leading: CircleAvatar(child: Text(name.characters.first)),
            title: Text(name),
            subtitle: Text('$title · age $age'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
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
