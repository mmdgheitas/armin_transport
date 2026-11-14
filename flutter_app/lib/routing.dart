/// Which screen a location leads to. Pure rules without widgets, so that they can be tested on their own.
library;

/// The locations of the app. They are the same as in the web client.
abstract final class AppPaths {
  static const String home = '/';
  static const String setup = '/setup';
  static const String track = '/track';
  static const String login = '/login';
  static const String dashboard = '/dashboard';
  static const String shipments = '/shipments';
  static const String newShipment = '/shipments/new';
  static const String companies = '/companies';
  static const String users = '/users';
  static const String productFields = '/product-fields';
  static const String auditLogs = '/audit-logs';
  static const String profile = '/profile';

  static String shipment(String id) => '/shipments/${Uri.encodeComponent(id)}';

  /// The list of users, limited to the employees of one company.
  static String usersOf(String companyId) => Uri(path: users, queryParameters: {'company_id': companyId}).toString();

  /// The login screen that continues at [next] after a successful login.
  static String loginThen(String next) => Uri(path: login, queryParameters: {'next': next}).toString();
}

/// An entry of the main navigation. It is shown to users who hold [permission].
///
/// A screen without an entry stays in the app (its route, its title and its tests), it is only not offered.
class NavEntry {
  const NavEntry(this.path, this.label, this.permission);

  final String path;
  final String label;
  final String permission;
}

const List<NavEntry> navEntries = [
  NavEntry(AppPaths.dashboard, 'داشبورد', 'dashboard:view'),
  NavEntry(AppPaths.shipments, 'محموله‌ها', 'shipment:view'),
  NavEntry(AppPaths.companies, 'شرکت‌ها', 'company:view'),
  NavEntry(AppPaths.users, 'کاربران', 'user:view'),
  // NavEntry(AppPaths.productFields, 'فیلدهای محموله', 'product_field:manage'),
  // NavEntry(AppPaths.auditLogs, 'گزارش رویدادها', 'audit_log:view'),
];

/// The name of the app as the user sees it.
const String appName = 'حمل‌ونقل';

/// The title of the staff screen at [path], shown in the bar above it.
String titleOf(String path) {
  final normalized = _normalize(path);
  if (normalized == AppPaths.profile) return 'حساب کاربری';
  if (normalized == AppPaths.newShipment) return 'ثبت محمولهٔ جدید';
  if (normalized.startsWith('${AppPaths.shipments}/')) return 'جزئیات محموله';
  for (final entry in navEntries) {
    if (normalized == entry.path) return entry.label;
  }
  // Screens that have no entry in the navigation at the moment.
  if (normalized == AppPaths.productFields) return 'فیلدهای محموله';
  if (normalized == AppPaths.auditLogs) return 'گزارش رویدادها';
  return appName;
}

String _normalize(String path) {
  if (path.isEmpty) return AppPaths.home;
  final trimmed = path.length > 1 ? path.replaceAll(RegExp(r'/+$'), '') : path;
  return trimmed.isEmpty ? AppPaths.home : trimmed;
}

/// The navigation entry that [path] belongs to: `/shipments/42` belongs to `/shipments`. `null` for other screens.
String? navPathOf(String path) {
  final normalized = _normalize(path);
  for (final entry in navEntries) {
    if (normalized == entry.path || normalized.startsWith('${entry.path}/')) return entry.path;
  }
  return null;
}

/// Where the visitor has to go instead of [location], or `null` when [location] is the right place.
///
/// - Without the address of a server nothing but the setup screen is usable.
/// - The tracking screen is open to everyone; every other screen needs a signed-in employee.
/// - Whoever is sent to the login screen continues afterwards where they wanted to go.
String? redirectFor(
  Uri location, {
  required bool hasServer,
  required bool serverIsFixed,
  required bool signedIn,
}) {
  final path = _normalize(location.path);
  if (!hasServer) return path == AppPaths.setup ? null : AppPaths.setup;
  // An address that is built into the app cannot be changed, so there is nothing to set up.
  if (path == AppPaths.setup) return serverIsFixed ? AppPaths.home : null;
  if (path == AppPaths.home) return signedIn ? AppPaths.dashboard : AppPaths.track;
  if (path == AppPaths.track) return null;
  if (path == AppPaths.login) return signedIn ? safeNextLocation(location.queryParameters['next']) : null;
  return signedIn ? null : AppPaths.loginThen(location.toString());
}

final RegExp _inAppLocation = RegExp(r'^/[^/\\]');

/// The location to continue at after a login. Only locations inside the app are accepted;
/// anything else leads to [fallback].
String safeNextLocation(String? next, {String fallback = AppPaths.dashboard}) {
  if (next == null || !_inAppLocation.hasMatch(next)) return fallback;
  final uri = Uri.tryParse(next);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return fallback;
  final path = _normalize(uri.path);
  if (path == AppPaths.login || path == AppPaths.setup) return fallback;
  return next;
}
