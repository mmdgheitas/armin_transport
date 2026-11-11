import 'package:armin_transport/routing.dart';
import 'package:flutter_test/flutter_test.dart';

String? go(String location, {bool hasServer = true, bool serverIsFixed = false, bool signedIn = false}) =>
    redirectFor(Uri.parse(location), hasServer: hasServer, serverIsFixed: serverIsFixed, signedIn: signedIn);

void main() {
  test('without a server address only the setup screen is usable', () {
    for (final location in ['/', '/track', '/login', '/dashboard', '/shipments/42', '/nowhere']) {
      expect(go(location, hasServer: false), '/setup', reason: location);
      expect(go(location, hasServer: false, signedIn: true), '/setup', reason: location);
    }
    expect(go('/setup', hasServer: false), isNull);
  });

  test('the setup screen stays reachable unless the address is built in', () {
    expect(go('/setup'), isNull);
    expect(go('/setup', signedIn: true), isNull);
    expect(go('/setup', serverIsFixed: true), '/');
    expect(go('/setup/', serverIsFixed: true), '/');
  });

  test('the start location depends on who is using the app', () {
    expect(go('/'), '/track');
    expect(go('/', signedIn: true), '/dashboard');
    expect(go(''), '/track');
  });

  test('the tracking screen is open to everyone', () {
    expect(go('/track'), isNull);
    expect(go('/track', signedIn: true), isNull);
    expect(go('/track/'), isNull);
  });

  test('staff screens send a visitor to the login screen and remember the destination', () {
    expect(go('/dashboard'), '/login?next=%2Fdashboard');
    expect(go('/shipments/42'), '/login?next=%2Fshipments%2F42');
    expect(go('/shipments?status=ARCHIVED&page=2'), '/login?next=%2Fshipments%3Fstatus%3DARCHIVED%26page%3D2');
    expect(go('/profile'), '/login?next=%2Fprofile');
    expect(go('/nowhere'), '/login?next=%2Fnowhere');
    for (final location in ['/dashboard', '/shipments', '/shipments/new', '/shipments/42', '/companies', '/profile']) {
      expect(go(location, signedIn: true), isNull, reason: location);
    }
  });

  test('a remembered destination survives the round trip through the login screen', () {
    const wanted = '/shipments?status=ARCHIVED&q=یخچال ۲';
    final login = Uri.parse(go(Uri.parse(wanted).toString())!);
    expect(login.path, '/login');
    final next = login.queryParameters['next']!;
    expect(Uri.parse(next).queryParameters, {'status': 'ARCHIVED', 'q': 'یخچال ۲'});
    expect(go(login.toString(), signedIn: true), next);
  });

  test('the login screen is for visitors only', () {
    expect(go('/login'), isNull);
    expect(go('/login?next=%2Fshipments'), isNull);
    expect(go('/login', signedIn: true), '/dashboard');
    expect(go('/login?next=%2Fshipments%2F42', signedIn: true), '/shipments/42');
  });

  test('only locations inside the app are accepted after a login', () {
    expect(safeNextLocation('/shipments/42'), '/shipments/42');
    expect(safeNextLocation('/shipments?page=2'), '/shipments?page=2');
    expect(safeNextLocation('/track'), '/track');
    for (final unsafe in <String?>[
      null,
      '',
      '/',
      'shipments',
      '//evil.example/x',
      r'/\evil.example',
      'https://evil.example/',
      'javascript:alert(1)',
      '/login',
      '/login?next=%2Flogin',
      '/login/',
      '/setup',
    ]) {
      expect(safeNextLocation(unsafe), '/dashboard', reason: '$unsafe');
    }
    expect(safeNextLocation(null, fallback: '/track'), '/track');
  });

  test('finds the navigation entry a location belongs to', () {
    expect(navPathOf('/shipments'), '/shipments');
    expect(navPathOf('/shipments/new'), '/shipments');
    expect(navPathOf('/shipments/42/'), '/shipments');
    expect(navPathOf('/product-fields'), '/product-fields');
    expect(navPathOf('/profile'), isNull);
    expect(navPathOf('/shipmentsX'), isNull);
    expect(navPathOf('/'), isNull);
  });

  test('names the staff screens', () {
    expect(titleOf('/dashboard'), 'داشبورد');
    expect(titleOf('/shipments'), 'محموله‌ها');
    expect(titleOf('/shipments/new'), 'ثبت محمولهٔ جدید');
    expect(titleOf('/shipments/42'), 'جزئیات محموله');
    expect(titleOf('/profile/'), 'حساب کاربری');
    expect(titleOf('/nowhere'), appName);
  });

  test('builds locations', () {
    expect(AppPaths.shipment('42'), '/shipments/42');
    expect(AppPaths.shipment('a/b'), '/shipments/a%2Fb');
    expect(AppPaths.loginThen('/shipments/42'), '/login?next=%2Fshipments%2F42');
    expect(AppPaths.usersOf('c1'), '/users?company_id=c1');
    expect(Uri.parse(AppPaths.usersOf('a&b=c')).queryParameters, {'company_id': 'a&b=c'});
    expect(navEntries.map((entry) => entry.path).toSet().length, navEntries.length);
  });
}
