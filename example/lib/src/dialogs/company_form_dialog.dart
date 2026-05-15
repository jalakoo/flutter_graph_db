import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Submitted Company form values.
class CompanyFormResult {
  final String name;
  final int foundedYear;
  const CompanyFormResult({required this.name, required this.foundedYear});
}

/// Add / edit dialog for a Company. Pass [initial] to pre-fill.
class CompanyFormDialog extends StatefulWidget {
  final String title;
  final CompanyFormResult? initial;
  const CompanyFormDialog({super.key, required this.title, this.initial});

  static Future<CompanyFormResult?> show(
    BuildContext context, {
    required String title,
    CompanyFormResult? initial,
  }) =>
      showDialog<CompanyFormResult>(
        context: context,
        builder: (_) => CompanyFormDialog(title: title, initial: initial),
      );

  @override
  State<CompanyFormDialog> createState() => _CompanyFormDialogState();
}

class _CompanyFormDialogState extends State<CompanyFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _foundedYear;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? '');
    _foundedYear =
        TextEditingController(text: i == null ? '' : '${i.foundedYear}');
  }

  @override
  void dispose() {
    _name.dispose();
    _foundedYear.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(CompanyFormResult(
      name: _name.text.trim(),
      foundedYear: int.parse(_foundedYear.text.trim()),
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
                controller: _foundedYear,
                decoration:
                    const InputDecoration(labelText: 'Founded year'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return 'Required';
                  final n = int.tryParse(s);
                  if (n == null || n < 1500 || n > 2100) return 'Invalid';
                  return null;
                },
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
