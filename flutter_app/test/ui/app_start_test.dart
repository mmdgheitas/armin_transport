import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/routing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

void main() {
  testWidgets('asks for the address of the server on first start', (tester) async {
    final app = await pumpApp(
      tester,
      server: null,
      routes: {
        'GET /health': (request) => ok({'status': 'ok', 'version': '1.0.0'}),
      },
    );
    expect(find.text('نشانی سرور'), findsWidgets);
    expect(app.requests, isEmpty);

    // An address on the internet has to be encrypted.
    await tester.enterText(find.byType(TextField), 'http://example.com');
    await tester.tap(button('بررسی و ادامه'));
    await tester.pumpAndSettle();
    expect(find.textContaining('فقط نشانی امن (https)'), findsOneWidget);
    expect(app.requests, isEmpty);

    await tester.enterText(find.byType(TextField), 'armin.test');
    await tester.tap(button('بررسی و ادامه'));
    await tester.pumpAndSettle();
    expect(app.requests, ['GET /health']);
    expect(app.calls.single.uri.toString(), 'https://armin.test/api/v1/health');
    expect(app.session.serverUrl, testServer);
    // A visitor lands on the tracking screen.
    expect(find.text('رهگیری محموله'), findsOneWidget);
    expect(find.text('armin.test'), findsOneWidget);
  });

  testWidgets('does not accept an address that is not an Armin server', (tester) async {
    final app = await pumpApp(
      tester,
      server: null,
      routes: {'GET /health': (request) => textResponse(200, '<html>hello</html>')},
    );
    await tester.enterText(find.byType(TextField), 'https://other.example');
    await tester.tap(button('بررسی و ادامه'));
    await tester.pumpAndSettle();
    expect(find.textContaining('سرور حمل‌ونقل پاسخ نداد'), findsOneWidget);
    expect(app.session.serverUrl, isNull);
  });

  testWidgets('a visitor starts at the tracking screen and can reach the login screen', (tester) async {
    await pumpApp(tester);
    expect(find.text('رهگیری محموله'), findsOneWidget);
    await tester.tap(button('ورود کارکنان'));
    await tester.pumpAndSettle();
    expect(find.text('ورود کارکنان'), findsOneWidget);
    expect(find.textContaining('نام کاربری'), findsWidgets);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('a staff location leads to the login screen and continues there after the login', (tester) async {
    final app = await pumpApp(
      tester,
      location: '/profile',
      routes: {'POST /auth/login': (request) => ok(authPayload(), message: 'خوش آمدید.')},
    );
    expect(find.text('ورود کارکنان'), findsOneWidget);

    // Nothing is sent before both fields are filled in.
    await tester.tap(button('ورود'));
    await tester.pumpAndSettle();
    expect(find.text('نام کاربری را وارد کنید.'), findsOneWidget);
    expect(find.text('رمز عبور را وارد کنید.'), findsOneWidget);
    expect(app.requests, isEmpty);

    await tester.enterText(find.byType(TextField).at(0), '  armin.operator ');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse battery');
    await tester.tap(button('ورود'));
    await tester.pumpAndSettle();

    expect(app.requests, ['POST /auth/login']);
    expect(app.calls.single.json, {'username': 'armin.operator', 'password': 'correct horse battery'});
    expect(app.session.isSignedIn, isTrue);
    expect(find.text('خوش آمدید.'), findsOneWidget);
    // The profile page that was asked for, inside the staff frame.
    expect(find.text('تغییر رمز عبور'), findsWidgets);
    expect(find.text('armin.operator'), findsWidgets);
  });

  testWidgets('shows why the login failed', (tester) async {
    final app = await pumpApp(
      tester,
      location: '/login',
      routes: {
        'POST /auth/login': (request) =>
            errorResponse(401, 'invalid_credentials', message: 'نام کاربری یا رمز عبور نادرست است.'),
      },
    );
    await tester.enterText(find.byType(TextField).at(0), 'armin.operator');
    await tester.enterText(find.byType(TextField).at(1), 'wrong');
    await tester.tap(button('ورود'));
    await tester.pumpAndSettle();
    expect(find.text('نام کاربری یا رمز عبور نادرست است.'), findsOneWidget);
    expect(app.session.isSignedIn, isFalse);
  });

  testWidgets('a signed-in employee starts at the dashboard', (tester) async {
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      routes: {'GET /dashboard/summary': (request) => ok(dashboardJson())},
    );
    expect(app.requests, containsAll(<String>['GET /auth/me', 'GET /dashboard/summary']));
    expect(find.text('سارا محمدی، خوش آمدید'), findsOneWidget);
    expect(find.text('خلاصهٔ وضعیت حمل‌ونقل'), findsOneWidget);
    // The four numbers of the company.
    expect(find.text('۱٬۲۸۴'), findsOneWidget);
    for (final label in ['کل محموله‌ها', 'محموله‌های فعال', 'محموله‌های بایگانی‌شده', 'سندهای بارگذاری‌شده']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // An employee sees the sections of the own company only.
    expect(find.text('محموله‌ها'), findsOneWidget);
    expect(find.text('شرکت‌ها'), findsNothing);
    expect(find.text('کاربران'), findsNothing);
    expect(find.text('گزارش رویدادها'), findsNothing);
  });

  testWidgets('the central administrator sees the numbers and the sections of all companies', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      routes: {'GET /dashboard/summary': (request) => ok(dashboardJson(global: true))},
    );
    expect(find.text('خلاصهٔ وضعیت همهٔ شرکت‌ها'), findsOneWidget);
    expect(find.text('کل محموله‌ها'), findsOneWidget);
    for (final section in ['داشبورد', 'محموله‌ها', 'شرکت‌ها', 'کاربران']) {
      expect(find.text(section), findsWidgets, reason: section);
    }
    // The administrator holds every permission, so every entry of the navigation is offered.
    for (final entry in navEntries) {
      expect(find.text(entry.label), findsWidgets, reason: entry.path);
    }
  });

  testWidgets('the dashboard offers a retry when the server cannot be reached', (tester) async {
    var attempts = 0;
    await pumpApp(
      tester,
      auth: authPayload(),
      routes: {
        'GET /dashboard/summary': (request) {
          attempts += 1;
          return attempts == 1
              ? errorResponse(503, 'service_unavailable', message: 'سرور در دسترس نیست.')
              : ok(dashboardJson(recent: const <Json>[]));
        },
      },
    );
    expect(find.text('سرور در دسترس نیست.'), findsOneWidget);
    expect(find.textContaining('req-test-0001'), findsOneWidget);
    await tester.tap(button('تلاش دوباره'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('سرور در دسترس نیست.'), findsNothing);
    expect(find.text('کل محموله‌ها'), findsOneWidget);
  });

  testWidgets('logging out revokes the session and leads to the login screen', (tester) async {
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      routes: {
        'GET /dashboard/summary': (request) => ok(dashboardJson()),
        'POST /auth/logout': (request) => ok(null, message: 'خارج شدید.'),
      },
    );
    await tester.tap(button('خروج'));
    await tester.pumpAndSettle();
    expect(app.requests.last, 'POST /auth/logout');
    expect(app.calls.last.authorization, 'Bearer access-1');
    expect(app.session.isSignedIn, isFalse);
    expect(find.text('ورود کارکنان'), findsOneWidget);
    expect(find.text('از حساب کاربری خود خارج شدید.'), findsOneWidget);
  });

  testWidgets('on a phone the navigation is a drawer', (tester) async {
    await pumpApp(
      tester,
      size: phoneSize,
      auth: adminAuthPayload(),
      routes: {'GET /dashboard/summary': (request) => ok(dashboardJson(global: true))},
    );
    expect(tester.takeException(), isNull);
    expect(find.text('شرکت‌ها'), findsNothing);
    await tester.tap(find.byTooltip('فهرست اصلی'));
    await tester.pumpAndSettle();
    expect(find.text('شرکت‌ها'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    // Choosing a section closes the drawer.
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('داشبورد')));
    await tester.pumpAndSettle();
    expect(find.text('شرکت‌ها'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a location that leads nowhere says so', (tester) async {
    await pumpApp(tester, auth: authPayload(), location: '/nowhere');
    expect(find.text('صفحه یافت نشد'), findsOneWidget);
  });

  testWidgets('a page without permission is replaced by a notice', (tester) async {
    final app = await pumpApp(
      tester,
      location: '/dashboard',
      auth: authPayload('1', const {
        'permissions': <String>['shipment:view'],
      }),
    );
    expect(find.text('عدم دسترسی'), findsOneWidget);
    expect(app.requests, ['GET /auth/me']);
  });
}
