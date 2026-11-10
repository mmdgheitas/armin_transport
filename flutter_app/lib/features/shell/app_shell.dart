/// The frame of the staff screens: the navigation, the signed-in user and the bar above the page.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/feedback.dart';
import 'public_scaffold.dart';

/// From this width on the navigation stays on screen; below it is a drawer.
const double _wideLayout = 960;

const Map<String, IconData> _navIcons = {
  AppPaths.dashboard: Icons.dashboard_outlined,
  AppPaths.shipments: Icons.inventory_2_outlined,
  AppPaths.companies: Icons.business_outlined,
  AppPaths.users: Icons.people_outline,
  AppPaths.productFields: Icons.tune,
  AppPaths.auditLogs: Icons.history,
};

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  /// The path of the page that [child] shows.
  final String location;
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _leaving = false;

  void _go(String path) {
    _scaffoldKey.currentState?.closeDrawer();
    context.go(path);
  }

  Future<void> _logout() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    // Taken before the session ends: afterwards this screen is gone.
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(apiClientProvider).logout();
    router.go(AppPaths.login);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('از حساب کاربری خود خارج شدید.')));
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    // The session has just ended; the router is about to show the login screen.
    if (auth == null) return const Scaffold(body: LoadingBlock(text: 'در حال خروج…'));

    final wide = MediaQuery.sizeOf(context).width >= _wideLayout;
    final sidebar = _Sidebar(auth: auth, activePath: navPathOf(widget.location), onGo: _go);
    return Scaffold(
      key: _scaffoldKey,
      drawer: wide ? null : Drawer(width: 272, backgroundColor: AppColors.sidebar, child: sidebar),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide) SizedBox(width: 256, child: sidebar),
            // The key keeps the page (and what was typed into it) when the window is resized across the breakpoint.
            Expanded(
              key: const ValueKey<String>('page'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    title: titleOf(widget.location),
                    compact: !wide,
                    onMenu: () => _scaffoldKey.currentState?.openDrawer(),
                    onProfile: () => _go(AppPaths.profile),
                    onLogout: _leaving ? null : _logout,
                  ),
                  Expanded(child: widget.child),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar above the page: its title, and the way to the own account and out of the app.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.compact,
    required this.onMenu,
    required this.onProfile,
    required this.onLogout,
  });

  final String title;

  /// On a narrow screen: a button for the navigation drawer, and icons instead of labelled buttons.
  final bool compact;
  final VoidCallback onMenu;
  final VoidCallback onProfile;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: EdgeInsetsDirectional.only(start: compact ? 4 : 24, end: compact ? 4 : 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (compact) ...[
            IconButton(tooltip: 'فهرست اصلی', onPressed: onMenu, icon: const Icon(Icons.menu)),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (compact) ...[
            IconButton(tooltip: 'حساب کاربری', onPressed: onProfile, icon: const Icon(Icons.person_outline)),
            IconButton(tooltip: 'خروج', onPressed: onLogout, icon: const Icon(Icons.logout)),
          ] else ...[
            TextButton.icon(
              onPressed: onProfile,
              icon: const Icon(Icons.person_outline, size: 18),
              label: const Text('حساب کاربری'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(onPressed: onLogout, icon: const Icon(Icons.logout, size: 18), label: const Text('خروج')),
          ],
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.auth, required this.activePath, required this.onGo});

  final AuthSession auth;
  final String? activePath;
  final void Function(String path) onGo;

  @override
  Widget build(BuildContext context) {
    final user = auth.user;
    final company = user.company?.name;
    return Material(
      color: AppColors.sidebar,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(8, 6, 8, 18),
                child: Align(alignment: AlignmentDirectional.centerStart, child: Brand(color: Colors.white)),
              ),
              Expanded(
                child: Semantics(
                  label: 'فهرست اصلی',
                  container: true,
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final entry in navEntries)
                        if (auth.can(entry.permission))
                          _NavItem(
                            label: entry.label,
                            icon: _navIcons[entry.path] ?? Icons.circle_outlined,
                            active: entry.path == activePath,
                            onTap: () => onGo(entry.path),
                          ),
                    ],
                  ),
                ),
              ),
              const Divider(color: Color(0x1AFFFFFF)),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.fullName,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, height: 1.6),
                    ),
                    Text(
                      company == null ? user.roleLabel : '${user.roleLabel} · $company',
                      style: const TextStyle(color: AppColors.sidebarText, fontSize: 13, height: 1.6),
                    ),
                    Text(
                      user.username,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(color: AppColors.sidebarText, fontSize: 13, height: 1.6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.label, required this.icon, required this.active, required this.onTap});

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? Colors.white : AppColors.sidebarText;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? AppColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(radiusSmall),
        child: InkWell(
          borderRadius: BorderRadius.circular(radiusSmall),
          hoverColor: AppColors.sidebarHover,
          onTap: onTap,
          child: Semantics(
            selected: active,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of a page that the signed-in user may not see.
class ForbiddenPage extends StatelessWidget {
  const ForbiddenPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _MessagePage(
      icon: Icons.lock_outline,
      title: 'عدم دسترسی',
      text: 'شما اجازهٔ مشاهدهٔ این صفحه را ندارید.',
      onHome: () => context.go(AppPaths.home),
    );
  }
}

/// Shown for a location that leads nowhere.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _MessagePage(
          icon: Icons.search_off,
          title: 'صفحه یافت نشد',
          text: 'صفحهٔ موردنظر یافت نشد.',
          onHome: () => context.go(AppPaths.home),
        ),
      ),
    );
  }
}

class _MessagePage extends StatelessWidget {
  const _MessagePage({required this.icon, required this.title, required this.text, required this.onHome});

  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.borderStrong),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 20),
            FilledButton(onPressed: onHome, child: const Text('بازگشت به صفحهٔ اصلی')),
          ],
        ),
      ),
    );
  }
}
