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

/// The frame of a dialog that holds more than a sentence: the title stays in place, the content scrolls
/// when the screen is too short for it, and the buttons stay below.
///
/// The content has a fixed width and scrolls on its own, instead of `AlertDialog.scrollable`. To find its
/// width, a dialog of that kind asks its content how high it would like to be, and a widget that arranges
/// itself by the room it gets (a [LayoutBuilder], as in the form grid) has no answer to that question.
/// Here the dialog learns the width from the box around the content and never asks further down.
class DialogFrame extends StatelessWidget {
  const DialogFrame({super.key, required this.title, required this.child, required this.actions, this.width = 480});

  final String title;
  final Widget child;
  final List<Widget> actions;

  /// The width of the content on a screen that is wide enough for it.
  final double width;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: SizedBox(width: width, child: SingleChildScrollView(child: child)),
      actions: actions,
    );
  }
}

/// Shows a form in a dialog. Completes with what the form passed to `Navigator.pop`, or `null` when it was cancelled.
///
/// A tap beside the dialog does not close it: what was typed would be lost.
Future<T?> showFormDialog<T>(BuildContext context, WidgetBuilder builder) =>
    showDialog<T>(context: context, barrierDismissible: false, builder: builder);

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
    // While the server is working the dialog stays, also when the back button is pressed:
    // the form closes itself with the result.
    return PopScope(
      canPop: !busy,
      child: DialogFrame(
        title: title,
        width: width,
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.of(context).pop(), child: const Text('انصراف')),
          BusyButton(label: submitLabel, icon: submitIcon, busy: busy, danger: danger, onPressed: onSubmit),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, child) in children.indexed) ...[if (index > 0) const SizedBox(height: 16), child],
            if (error != null) ...[const SizedBox(height: 16), Notice(error, tone: Tone.danger)],
          ],
        ),
      ),
    );
  }
}
