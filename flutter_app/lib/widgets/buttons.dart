/// Buttons that show that their action is under way.
library;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

const Widget _spinner = SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));

/// A button that shows that its action is under way and cannot be pressed meanwhile.
class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.icon,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    return FilledButton.icon(
      style: danger ? FilledButton.styleFrom(backgroundColor: AppColors.danger) : null,
      onPressed: busy ? null : onPressed,
      icon: busy ? _spinner : (icon == null ? null : Icon(icon, size: 18)),
      label: Text(label),
    );
  }
}

enum ButtonKind { filled, outlined, text }

/// A button that runs [onPressed] and shows a spinner until it completes; it cannot be pressed again meanwhile.
///
/// The action reports its own failures (for example with a message); it must not throw.
class ActionButton extends StatefulWidget {
  const ActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.confirm,
    this.icon,
    this.kind = ButtonKind.outlined,
    this.danger = false,
  });

  final String label;
  final Future<void> Function()? onPressed;

  /// Asked before [onPressed] runs, typically with a dialog; the action is dropped unless it completes with `true`.
  /// The spinner starts only afterwards: it stands for the server working, not for the user thinking.
  final Future<bool> Function()? confirm;
  final IconData? icon;
  final ButtonKind kind;
  final bool danger;

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _busy = false;

  Future<void> _run() async {
    final action = widget.onPressed;
    if (action == null || _busy) return;
    final confirm = widget.confirm;
    if (confirm != null) {
      final confirmed = await confirm();
      if (!confirmed) return;
      if (!mounted) return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final iconData = widget.icon;
    final icon = _busy ? _spinner : (iconData == null ? null : Icon(iconData, size: 18));
    final onPressed = widget.onPressed == null || _busy ? null : _run;
    final label = Text(widget.label);
    switch (widget.kind) {
      case ButtonKind.filled:
        return FilledButton.icon(
          style: widget.danger ? FilledButton.styleFrom(backgroundColor: AppColors.danger) : null,
          onPressed: onPressed,
          icon: icon,
          label: label,
        );
      case ButtonKind.outlined:
        return OutlinedButton.icon(
          style: widget.danger ? OutlinedButton.styleFrom(foregroundColor: AppColors.danger) : null,
          onPressed: onPressed,
          icon: icon,
          label: label,
        );
      case ButtonKind.text:
        return TextButton.icon(
          style: widget.danger ? TextButton.styleFrom(foregroundColor: AppColors.danger) : null,
          onPressed: onPressed,
          icon: icon,
          label: label,
        );
    }
  }
}
