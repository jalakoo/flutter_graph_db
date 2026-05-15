import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Submitted Person form values.
class PersonFormResult {
  final String name;
  final int age;
  final String title;
  const PersonFormResult({
    required this.name,
    required this.age,
    required this.title,
  });
}

/// Reusable dialog used both for **adding** a new Person and for
/// **editing** an existing one. Pass [initial] values to pre-fill.
class PersonFormDialog extends StatefulWidget {
  final String title;
  final PersonFormResult? initial;
  const PersonFormDialog({super.key, required this.title, this.initial});

  static Future<PersonFormResult?> show(
    BuildContext context, {
    required String title,
    PersonFormResult? initial,
  }) =>
      showDialog<PersonFormResult>(
        context: context,
        builder: (_) => PersonFormDialog(title: title, initial: initial),
      );

  @override
  State<PersonFormDialog> createState() => _PersonFormDialogState();
}

class _PersonFormDialogState extends State<PersonFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _age;
  late final TextEditingController _title;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? '');
    _age = TextEditingController(text: i == null ? '' : '${i.age}');
    _title = TextEditingController(text: i?.title ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(PersonFormResult(
      name: _name.text.trim(),
      age: int.parse(_age.text.trim()),
      title: _title.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _age,
                decoration: const InputDecoration(labelText: 'Age'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return 'Required';
                  final n = int.tryParse(s);
                  if (n == null || n < 0 || n > 200) return 'Invalid';
                  return null;
                },
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
