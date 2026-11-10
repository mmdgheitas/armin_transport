/// The login screen for employees.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/config.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../../widgets/form_support.dart';
import '../shell/public_scaffold.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with FormSupport<LoginScreen> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  /// Why the previous session was ended by the server; shown until the next attempt.
  String? _endReason;

  @override
  Set<String> get fieldNames => const {'username', 'password'};

  @override
  void initState() {
    super.initState();
    _endReason = ref.read(appSessionProvider).takeEndReason()?.message;
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text;
    final client = ref.read(apiClientProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _endReason = null);
    await runForm(
      problems: requiredProblems(
        {'username': username, 'password': password},
        {'username': 'نام کاربری را وارد کنید.', 'password': 'رمز عبور را وارد کنید.'},
      ),
      () async {
        final result = await client.login(username, password);
        // The router leaves this screen as soon as the session is stored; the message outlives it.
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(result.message), backgroundColor: AppColors.success));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appSessionProvider);
    final endReason = _endReason;
    final formError = this.formError;
    final server = ServerAddress.parse(app.serverUrl ?? '').displayHost;
    return PublicScaffold(
      maxWidth: 440,
      action: OutlinedButton.icon(
        onPressed: () => context.go(AppPaths.track),
        icon: const Icon(Icons.search, size: 18),
        label: const Text('رهگیری محموله'),
      ),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('ورود کارکنان', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text(
                    'برای ورود به پنل مدیریت محموله‌ها، نام کاربری و رمز عبور خود را وارد کنید.',
                    style: TextStyle(color: AppColors.muted, height: 1.7),
                  ),
                  if (endReason != null) ...[const SizedBox(height: 16), Notice(endReason, tone: Tone.warning)],
                  const SizedBox(height: 20),
                  AppTextField(
                    label: 'نام کاربری',
                    controller: _username,
                    isRequired: true,
                    ltr: true,
                    maxLength: 100,
                    autofocus: true,
                    enabled: !busy,
                    error: errors['username'],
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                  ),
                  const SizedBox(height: 16),
                  PasswordField(
                    label: 'رمز عبور',
                    controller: _password,
                    enabled: !busy,
                    error: errors['password'],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (formError != null) ...[const SizedBox(height: 16), Notice(formError, tone: Tone.danger)],
                  const SizedBox(height: 20),
                  BusyButton(label: 'ورود', icon: Icons.lock_outline, busy: busy, onPressed: _submit),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('مشتری هستید؟', style: TextStyle(fontSize: 13, color: AppColors.muted)),
            TextButton(
              onPressed: () => context.go(AppPaths.track),
              child: const Text('محمولهٔ خود را با کد رهگیری پیدا کنید.'),
            ),
          ],
        ),
        if (server.isNotEmpty) ServerLine(host: server, canChange: !app.serverIsFixed),
      ],
    );
  }
}
