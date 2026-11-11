/// The app: its routes, its look and its language.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'core/api/api_error.dart';
import 'core/providers.dart';
import 'core/session.dart';
import 'features/audit/audit_logs_page.dart';
import 'features/auth/login_screen.dart';
import 'features/companies/companies_page.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/product_fields/product_fields_page.dart';
import 'features/profile/profile_page.dart';
import 'features/setup/setup_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/shipments/shipment_detail_page.dart';
import 'features/shipments/shipment_new_page.dart';
import 'features/shipments/shipments_page.dart';
import 'features/track/track_screen.dart';
import 'features/users/users_page.dart';
import 'routing.dart';
import 'theme.dart';

/// A staff page: shown to users who hold [permission], otherwise the "no access" page takes its place.
class _Guarded extends ConsumerWidget {
  const _Guarded({required this.permission, required this.child});

  /// `null` for pages that every signed-in user may see.
  final String? permission;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final permission = this.permission;
    final Widget content;
    if (auth == null) {
      // The session has just ended; the router is about to show the login screen.
      content = const SizedBox.shrink();
    } else if (permission != null && !auth.can(permission)) {
      content = const ForbiddenPage();
    } else {
      content = child;
    }
    return Material(color: AppColors.background, child: content);
  }
}

/// A section of the navigation. Sections replace each other at once, like the tabs of a desktop program.
GoRoute _section(
  String path,
  String? permission,
  Widget Function(GoRouterState state) page, {
  List<RouteBase> routes = const <RouteBase>[],
}) => GoRoute(
  path: path,
  pageBuilder: (context, state) => NoTransitionPage<void>(
    key: state.pageKey,
    child: _Guarded(permission: permission, child: page(state)),
  ),
  routes: routes,
);

/// The routes of the app. Who may go where is decided by [redirectFor].
GoRouter buildRouter(AppSession app, {String? initialLocation}) => GoRouter(
  initialLocation: initialLocation ?? AppPaths.home,
  refreshListenable: app,
  redirect: (context, state) => redirectFor(
    state.uri,
    hasServer: app.serverUrl != null,
    serverIsFixed: app.serverIsFixed,
    signedIn: app.isSignedIn,
  ),
  errorBuilder: (context, state) => const NotFoundScreen(),
  routes: [
    // Never shown: the start location always leads on to the dashboard or to the tracking screen.
    GoRoute(path: AppPaths.home, builder: (context, state) => const Scaffold()),
    GoRoute(path: AppPaths.setup, builder: (context, state) => const SetupScreen()),
    GoRoute(path: AppPaths.track, builder: (context, state) => const TrackScreen()),
    GoRoute(path: AppPaths.login, builder: (context, state) => const LoginScreen()),
    ShellRoute(
      builder: (context, state, child) => AppShell(location: state.uri.path, child: child),
      routes: [
        _section(AppPaths.dashboard, 'dashboard:view', (state) => const DashboardPage()),
        _section(
          AppPaths.shipments,
          'shipment:view',
          (state) => const ShipmentsPage(),
          // These pages lie on top of the list, which is where "back" leads. "new" has to come first:
          // it would pass for an identifier.
          routes: [
            _section('new', 'shipment:create', (state) => const ShipmentNewPage()),
            _section(':id', 'shipment:view', (state) {
              final id = state.pathParameters['id'] ?? '';
              // The key makes another shipment another page, not new content for the page of the last one.
              return ShipmentDetailPage(key: ValueKey<String>(id), shipmentId: id);
            }),
          ],
        ),
        _section(AppPaths.companies, 'company:view', (state) => const CompaniesPage()),
        _section(AppPaths.users, 'user:view', (state) {
          final companyId = state.uri.queryParameters['company_id'];
          // The location may name a company (the link from the list of companies). The key makes
          // that a page of its own, which starts with the filter set.
          return UsersPage(key: ValueKey<String>('users-${companyId ?? ''}'), companyId: companyId);
        }),
        _section(AppPaths.productFields, 'product_field:manage', (state) => const ProductFieldsPage()),
        _section(AppPaths.auditLogs, 'audit_log:view', (state) => const AuditLogsPage()),
        _section(AppPaths.profile, null, (state) => const ProfilePage()),
      ],
    ),
  ],
);

class ArminApp extends ConsumerStatefulWidget {
  const ArminApp({super.key, this.location});

  /// Where the app starts; tests use it to open a screen directly.
  final String? location;

  @override
  ConsumerState<ArminApp> createState() => _ArminAppState();
}

class _ArminAppState extends ConsumerState<ArminApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    final app = ref.read(appSessionProvider);
    _router = buildRouter(app, initialLocation: widget.location);
    // The stored profile may be days old: permissions and settings are read again in the background.
    if (app.isSignedIn) unawaited(_refreshProfile());
  }

  Future<void> _refreshProfile() async {
    try {
      await ref.read(apiClientProvider).refreshProfile();
    } on ApiError {
      // Without a connection the stored profile is used; a session that is no longer valid has been ended by the client.
    }
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      locale: const Locale('fa'),
      supportedLocales: const [Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: _router,
      // Dark status-bar icons on the light background of every screen.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
