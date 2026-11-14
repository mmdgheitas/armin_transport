/// Asks for the address of the server. Shown on first start, and later when the user wants another server.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_error.dart';
import '../../core/api/armin_api.dart';
import '../../core/config.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/buttons.dart';
import '../../widgets/feedback.dart';
import '../../widgets/fields.dart';
import '../shell/public_scaffold.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  late final TextEditingController _address;
  bool _busy = false;
  String? _fieldError;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(
      text: ref.read(appSessionProvider).serverUrl ?? '',
    );
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final address = ServerAddress.parse(_address.text);
    final baseUrl = address.baseUrl;
    if (baseUrl == null) {
      setState(() {
        _fieldError = address.problem;
        _failure = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _fieldError = null;
      _failure = null;
    });
    final app = ref.read(appSessionProvider);
    try {
      // Ask the server who it is before trusting the address.
      final client = createApiClient(
        baseUrl: baseUrl,
        dio: ref.read(dioProvider),
        app: app,
      );
      await ArminApi(client).serverVersion();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = error is ApiError && error.isNetworkError
            ? 'اتصال به این نشانی برقرار نشد. نشانی و اتصال شبکه را بررسی کنید.'
            : 'در این نشانی سرور $appName پاسخ نداد. نشانی را بررسی کنید.';
      });
      return;
    }
    if (!mounted) return;
    app.setServer(baseUrl);
    context.go(AppPaths.home);
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appSessionProvider);
    final current = app.serverUrl;
    final typed = ServerAddress.parse(_address.text);
    final failure = _failure;
    return PublicScaffold(
      maxWidth: 520,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'نشانی سرور',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'نشانی سامانهٔ $appName را وارد کنید. این نشانی را مدیر سامانه در اختیار شما می‌گذارد.',
                  style: TextStyle(color: AppColors.muted, height: 1.7),
                ),
                const SizedBox(height: 20),
                AppTextField(
                  label: 'نشانی سرور',
                  controller: _address,
                  isRequired: true,
                  ltr: true,
                  maxLength: 300,
                  placeholder: 'https://example.com',
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  error: _fieldError,
                  hint: 'اتصال رمزنگاری‌نشده (http) فقط برای سرورهای شبکهٔ داخلی پذیرفته می‌شود.',
                  enabled: !_busy,
                  autofocus: current == null,
                  onChanged: (_) => setState(() => _fieldError = null),
                  onSubmitted: (_) => _submit(),
                ),
                if (typed.isInsecure) ...[
                  const SizedBox(height: 12),
                  const Notice(
                    'ارتباط با این نشانی رمزنگاری نمی‌شود. فقط در شبکهٔ داخلی مورد اعتماد از آن استفاده کنید.',
                    tone: Tone.warning,
                  ),
                ],
                if (current != null && app.isSignedIn) ...[
                  const SizedBox(height: 12),
                  const Notice(
                    'با تغییر نشانی سرور از حساب کاربری خود خارج می‌شوید.',
                  ),
                ],
                if (failure != null) ...[
                  const SizedBox(height: 12),
                  Notice(failure, tone: Tone.danger),
                ],
                const SizedBox(height: 20),
                BusyButton(
                  label: 'بررسی و ادامه',
                  icon: Icons.arrow_forward,
                  busy: _busy,
                  onPressed: _submit,
                ),
                if (current != null) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : () => context.go(AppPaths.home),
                    child: const Text('انصراف'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
