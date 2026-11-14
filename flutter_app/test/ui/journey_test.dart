import 'package:armin_transport/routing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

const String code = 'ARMN-7K2M-9QXD-4T8B';

void main() {
  testWidgets('on a phone an administrator gets to every section of the navigation and out again', (tester) async {
    final app = await pumpApp(
      tester,
      size: phoneSize,
      auth: adminAuthPayload(),
      routes: {
        'GET /dashboard/summary': (request) => ok(dashboardJson(global: true)),
        'GET /shipments': (request) => ok(pageOf([shipmentJson()])),
        'GET /shipments/s1': (request) => ok(shipmentJson()),
        'GET /shipments/s1/product-values': (request) => ok({
          'items': [valueJson(fieldJson(), 120)],
        }),
        'GET /companies': (request) => ok(pageOf([companyJson()])),
        'GET /users': (request) => ok(pageOf([userJson()])),
        'GET /product-fields': (request) => ok(pageOf([fieldJson()])),
        'GET /audit-logs': (request) => ok(pageOf([auditJson()])),
        'POST /auth/logout': (request) => ok(null, message: 'خارج شدید.'),
      },
    );

    // Opens the drawer and chooses a section in it. Nothing may be cut off or pushed off the screen on the way.
    Future<void> go(String section) async {
      await tapOn(tester, find.byTooltip('فهرست اصلی'));
      expect(tester.takeException(), isNull, reason: 'the drawer before $section');
      await tapOn(tester, find.descendant(of: find.byType(Drawer), matching: find.text(section)));
      expect(find.byType(Drawer), findsNothing);
      expect(tester.takeException(), isNull, reason: section);
    }

    // Whether the navigation offers a section is decided by the list of its entries in lib/routing.dart.
    bool offered(String path) => navEntries.any((entry) => entry.path == path);

    expect(tester.takeException(), isNull);
    expect(app.requests, contains('GET /dashboard/summary'));

    await go('محموله‌ها');
    expect(find.text(code), findsOneWidget);

    // A shipment opens from its card; the arrow leads back to the list.
    await tapOn(tester, find.text(code));
    expect(tester.takeException(), isNull);
    expect(find.text('وزن (کیلوگرم)'), findsOneWidget);
    await tapOn(tester, find.byTooltip('بازگشت به فهرست'));
    expect(tester.takeException(), isNull);
    expect(find.text('وزن (کیلوگرم)'), findsNothing);
    expect(find.text(code), findsOneWidget);

    await go('شرکت‌ها');
    expect(find.text('SHARGH'), findsOneWidget);

    await go('کاربران');
    expect(find.text('armin.operator'), findsOneWidget);

    if (offered(AppPaths.productFields)) {
      await go('فیلدهای محموله');
      expect(find.text('weight'), findsOneWidget);
    }

    if (offered(AppPaths.auditLogs)) {
      await go('گزارش رویدادها');
      expect(badge('ثبت محموله'), findsOneWidget);
    }

    await go('داشبورد');
    expect(app.count('GET /dashboard/summary'), 2);

    // The own account and the way out are icons in the bar on top.
    await tapOn(tester, find.byTooltip('حساب کاربری'));
    expect(tester.takeException(), isNull);
    expect(find.text('مشخصات'), findsOneWidget);
    expect(fieldShell('رمز عبور فعلی'), findsOneWidget);

    await tapOn(tester, find.byTooltip('خروج'));
    expect(tester.takeException(), isNull);
    expect(app.requests.last, 'POST /auth/logout');
    expect(app.session.isSignedIn, isFalse);
    expect(find.text('ورود کارکنان'), findsOneWidget);
  });
}
