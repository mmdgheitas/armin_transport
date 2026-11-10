/// Dialogs: asking for confirmation, and the frame of a form shown in a dialog.
library;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import 'buttons.dart';
import 'feedback.dart';

/// Asks the user to confirm something. Completes with `true` only when the confirm button was pressed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'تأیید',
  String cancelLabel = 'انصراف',
  bool danger = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(message, style: const TextStyle(height: 1.7)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(cancelLabel)),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: AppColors.danger) : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// The frame of a form in a dialog: title, fields, the message of the form, cancel and submit.
class FormDialog extends StatelessWidget {
  const FormDialog({
    super.key,
    required this.title,
    required this.children,
    required this.onSubmit,
    this.submitLabel = 'ذخیره',
    this.submitIcon,
    this.busy = false,
    this.error,
    this.danger = false,
    this.width = 480,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback onSubmit;
  final String submitLabel;
  final IconData? submitIcon;
  final bool busy;
  final String? error;
  final bool danger;
  final double width;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    return AlertDialog(
      title: Text(title),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, child) in children.indexed) ...[if (index > 0) const SizedBox(height: 16), child],
            if (error != null) ...[const SizedBox(height: 16), Notice(error, tone: Tone.danger)],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.of(context).pop(), child: const Text('انصراف')),
        BusyButton(label: submitLabel, icon: submitIcon, busy: busy, danger: danger, onPressed: onSubmit),
      ],
    );
  }
}
