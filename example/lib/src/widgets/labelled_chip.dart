import 'package:flutter/material.dart';

/// A small chip displaying `label · value` — used to surface node
/// properties consistently across screens.
class LabelledChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;

  const LabelledChip({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      avatar: icon == null ? null : Icon(icon, size: 18),
      label: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: '$label  ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ]),
      ),
    );
  }
}
