/// Telling the user what is going on: messages, loading, errors, empty lists and status badges.
library;

import 'package:material_ui/material_ui.dart';

import '../core/api/api_error.dart';
import '../core/format.dart';
import '../theme.dart';

const String unexpectedErrorMessage = 'خطای غیرمنتظره‌ای رخ داد. لطفاً دوباره تلاش کنید.';

/// The message to show for whatever was thrown.
String messageOf(Object error) => error is ApiError ? error.message : unexpectedErrorMessage;

/// Shows a short message at the bottom of the screen; a newer message replaces an older one.
void showMessage(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null || message.isEmpty) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.danger : AppColors.success,
        duration: Duration(seconds: error ? 8 : 4),
      ),
    );
}

void showError(BuildContext context, Object error) => showMessage(context, messageOf(error), error: true);

/// Text that always runs left to right: tracking codes, user names, file names with Latin letters.
class LtrText extends StatelessWidget {
  const LtrText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Text(text, textDirection: TextDirection.ltr, style: style);
}

class LoadingBlock extends StatelessWidget {
  const LoadingBlock({super.key, this.text = 'در حال دریافت اطلاعات…'});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 12),
            Text(text, style: const TextStyle(color: AppColors.muted)),
          ],
        ),
      ),
    );
  }
}

/// What went wrong, the request id for the support team, and a way to try again.
class ErrorBlock extends StatelessWidget {
  const ErrorBlock({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    final requestId = error is ApiError ? error.requestId : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 36, color: AppColors.danger),
            const SizedBox(height: 12),
            Text(messageOf(error), textAlign: TextAlign.center),
            if (requestId != null) ...[
              const SizedBox(height: 6),
              Text(
                'شناسهٔ پیگیری: ${ltrIsolate(requestId)}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 18), label: const Text('تلاش دوباره')),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyBlock extends StatelessWidget {
  const EmptyBlock({super.key, required this.title, this.icon = Icons.inbox_outlined, this.action});

  final String title;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.borderStrong),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

enum Tone { neutral, info, success, warning, danger }

({Color foreground, Color background}) _colorsOf(Tone tone) => switch (tone) {
  Tone.neutral => (foreground: AppColors.muted, background: AppColors.surfaceAlt),
  Tone.info => (foreground: AppColors.primaryDark, background: AppColors.infoSoft),
  Tone.success => (foreground: AppColors.success, background: AppColors.successSoft),
  Tone.warning => (foreground: AppColors.warning, background: AppColors.warningSoft),
  Tone.danger => (foreground: AppColors.danger, background: AppColors.dangerSoft),
};

/// A small coloured label, e.g. "فعال" or "بایگانی‌شده".
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.label, {super.key, this.tone = Tone.neutral});

  factory StatusBadge.active(bool isActive) =>
      isActive ? const StatusBadge('فعال', tone: Tone.success) : const StatusBadge('غیرفعال', tone: Tone.danger);

  factory StatusBadge.shipment(String status) => status == 'ARCHIVED'
      ? const StatusBadge('بایگانی‌شده', tone: Tone.warning)
      : const StatusBadge('فعال', tone: Tone.success);

  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final colors = _colorsOf(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: colors.background, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: colors.foreground)),
    );
  }
}

/// A message inside the page: the error of a form, a warning, a hint.
class Notice extends StatelessWidget {
  const Notice(this.message, {super.key, this.tone = Tone.info, this.icon});

  final String message;
  final Tone tone;
  final IconData? icon;

  static const Map<Tone, IconData> _icons = {
    Tone.neutral: Icons.info_outline,
    Tone.info: Icons.info_outline,
    Tone.success: Icons.check_circle_outline,
    Tone.warning: Icons.warning_amber_outlined,
    Tone.danger: Icons.error_outline,
  };

  @override
  Widget build(BuildContext context) {
    final colors = _colorsOf(tone);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(radiusSmall),
        border: Border.all(color: colors.foreground.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? _icons[tone], size: 20, color: colors.foreground),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: colors.foreground, height: 1.6))),
        ],
      ),
    );
  }
}
