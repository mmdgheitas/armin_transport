/// The frame of the screens for visitors who are not signed in: tracking, login and the server address.
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/feedback.dart';

/// The mark and the name of the app.
class Brand extends StatelessWidget {
  const Brand({super.key, this.color = AppColors.text});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primary, Color(0xFF2563EB), Color(0xFF0EA5E9)],
              stops: [0, 0.55, 1],
            ),
          ),
          child: const Icon(Icons.local_shipping_outlined, size: 22, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            appName,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color),
          ),
        ),
      ],
    );
  }
}

class PublicScaffold extends StatelessWidget {
  const PublicScaffold({super.key, required this.children, this.action, this.maxWidth = 760});

  /// The content, top to bottom.
  final List<Widget> children;

  /// A button at the end of the header, e.g. the way to the login screen.
  final Widget? action;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Expanded(child: Align(alignment: AlignmentDirectional.centerStart, child: Brand())),
                  if (action != null) ...[const SizedBox(width: 12), action],
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...children,
                        const SizedBox(height: 24),
                        const Text(
                          '© $appName',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: AppColors.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Names the server the app talks to and, unless the address is built in, leads to the screen that changes it.
class ServerLine extends StatelessWidget {
  const ServerLine({super.key, required this.host, required this.canChange});

  final String host;
  final bool canChange;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        const Text('سرور:', style: TextStyle(fontSize: 13, color: AppColors.muted)),
        LtrText(host, style: const TextStyle(fontSize: 13, color: AppColors.muted)),
        if (canChange) TextButton(onPressed: () => context.go(AppPaths.setup), child: const Text('تغییر')),
      ],
    );
  }
}
