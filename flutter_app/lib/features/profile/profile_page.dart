/// The own account: who is signed in, and changing the password.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    if (auth == null) return const SizedBox.shrink();
    final user = auth.user;
    final lastLogin = user.lastLoginAt;
    return PageBody(
      maxWidth: 760,
      children: [
        const PageHeader(title: 'حساب کاربری'),
        SectionCard(
          title: 'مشخصات',
          child: KeyValueList([
            ('نام', orDash(user.fullName)),
            ('نام کاربری', LtrText(user.username)),
            ('نقش', user.roleLabel),
            ('شرکت', user.company?.name),
            ('آخرین ورود', lastLogin == null ? null : formatDateTime(lastLogin, long: true)),
          ]),
        ),
        SectionCard(
          title: 'تغییر رمز عبور',
          child: _PasswordForm(minLength: auth.settings.passwordMinLength),
        ),
      ],
    );
  }
}

class _PasswordForm extends ConsumerStatefulWidget {
  const _PasswordForm({required this.minLength});

  final int minLength;

  @override
  ConsumerState<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends ConsumerState<_PasswordForm> with FormSupport<_PasswordForm> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  @override
  Set<String> get fieldNames => const {'current_password', 'new_password', 'confirm_password'};

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final current = _current.text;
    final next = _next.text;
    final confirm = _confirm.text;
    final problems = requiredProblems(
      {'current_password': current, 'new_password': next, 'confirm_password': confirm},
      {
        'current_password': 'رمز عبور فعلی را وارد کنید.',
        'new_password': 'رمز عبور جدید را وارد کنید.',
        'confirm_password': 'رمز عبور جدید را دوباره وارد کنید.',
      },
    );
    if (!problems.containsKey('confirm_password') && next != confirm) {
      problems['confirm_password'] = 'تکرار رمز عبور با رمز جدید یکسان نیست.';
    }
    final client = ref.read(apiClientProvider);
    String? message;
    final done = await runForm(problems: problems, () async {
      message = (await client.changePassword(current, next)).message;
    });
    if (!done) return;
    if (!mounted) return;
    _current.clear();
    _next.clear();
    _confirm.clear();
    showMessage(context, message ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final formError = this.formError;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'پس از تغییر رمز، نشست شما در دستگاه‌های دیگر بسته می‌شود.',
            style: TextStyle(fontSize: 13, color: AppColors.muted, height: 1.6),
          ),
          const SizedBox(height: 16),
          PasswordField(
            label: 'رمز عبور فعلی',
            controller: _current,
            enabled: !busy,
            error: errors['current_password'],
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          PasswordField(
            label: 'رمز عبور جدید',
            controller: _next,
            isNew: true,
            enabled: !busy,
            error: errors['new_password'],
            hint: 'دست‌کم ${toPersianDigits(widget.minLength)} نویسه؛ نباید شامل نام کاربری باشد.',
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          PasswordField(
            label: 'تکرار رمز عبور جدید',
            controller: _confirm,
            isNew: true,
            enabled: !busy,
            error: errors['confirm_password'],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
          if (formError != null) ...[const SizedBox(height: 16), Notice(formError, tone: Tone.danger)],
          const SizedBox(height: 20),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: BusyButton(label: 'تغییر رمز عبور', icon: Icons.key_outlined, busy: busy, onPressed: _submit),
          ),
        ],
      ),
    );
  }
}
