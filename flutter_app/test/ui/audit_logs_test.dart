import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/product_fields.dart';
import 'package:armin_transport/widgets/feedback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

const String code = 'ARMN-7K2M-9QXD-4T8B';

List<Json> threeEntries() => [
  // An employee recorded a shipment.
  auditJson(metadata: {'tracking_code_type': 'AUTO'}),
  // Somebody tried a user name that does not exist: no user, and here no address either.
  auditJson(
    id: 'a2',
    action: 'LOGIN_FAILED',
    entityType: 'user',
    entityId: null,
    byUser: false,
    ip: null,
    metadata: {'username': 'ghost', 'reason': 'unknown_user'},
  ),
  // Something a newer server records and this app has no name for.
  auditJson(id: 'a3', action: 'SOMETHING_NEW', entityType: 'gadget', entityId: 'g-17'),
];

/// The text boxes of the date field labelled [label]: the day first, then the year.
Finder dateBoxes(String label) => find.descendant(of: fieldShell(label), matching: find.byType(TextField));

String textOf(WidgetTester tester, Finder box) => tester.widget<TextField>(box).controller?.text ?? '';

/// What the page of a shipment asks for.
Map<String, RouteHandler> shipmentRoutes() => {
  'GET /shipments': (request) => ok(pageOf([shipmentJson()])),
  'GET /shipments/s1': (request) => ok(shipmentJson()),
  'GET /shipments/s1/product-values': (request) => ok({'items': const <Json>[]}),
  'GET /shipments/s1/documents': (request) => ok(pageOf(const <Json>[])),
  'GET /shipments/s1/tracking-history': (request) => ok(pageOf(const <Json>[])),
};

void main() {
  testWidgets('lists what happened and filters by event, kind and day', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/audit-logs',
      routes: {
        'GET /audit-logs': (request) =>
            ok(pageOf(request.query['entity_type'] == 'user' ? const <Json>[] : threeEntries())),
      },
    );
    expect(
      find.text('سابقهٔ ورودها، تغییرات و دسترسی‌ها برای بازبینی امنیتی. این گزارش قابل ویرایش یا حذف نیست.'),
      findsOneWidget,
    );
    expect(app.requests, unorderedEquals(['GET /auth/me', 'GET /audit-logs']));
    expect(app.last('GET /audit-logs').query, {'page': '1'});

    // Refusals and failures stand out; an event without a name here is shown as the server calls it.
    expect(tester.widget<StatusBadge>(badge('ثبت محموله')).tone, Tone.info);
    expect(tester.widget<StatusBadge>(badge('ورود ناموفق')).tone, Tone.warning);
    expect(tester.widget<StatusBadge>(badge('SOMETHING_NEW')).tone, Tone.info);
    expect(find.text('gadget'), findsOneWidget);
    expect(find.text('سارا محمدی'), findsNWidgets(2));
    expect(find.text('203.0.113.7'), findsNWidgets(2));
    expect(find.text('۳ مورد'), findsOneWidget);

    // A day without month and year is not a date: nothing is asked of the server.
    final from = dateBoxes('از تاریخ');
    final to = dateBoxes('تا تاریخ');
    await tester.enterText(from.at(0), '1');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(find.text('تاریخ واردشده کامل یا معتبر نیست.'), findsOneWidget);
    expect(app.count('GET /audit-logs'), 1);

    await choose(tester, 'رویداد', 'ورود ناموفق');
    await choose(tester, 'موجودیت', 'کاربر');
    await choose(tester, 'از تاریخ', 'فروردین');
    await tester.enterText(from.at(1), '1405');
    await tester.enterText(to.at(0), '۳۱');
    await choose(tester, 'تا تاریخ', 'شهریور');
    await tester.enterText(to.at(1), '۱۴۰۵');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(find.text('تاریخ واردشده کامل یا معتبر نیست.'), findsNothing);
    // Whole days of the device: from the first moment of the one to the last moment of the other.
    expect(app.last('GET /audit-logs').query, {
      'page': '1',
      'action': 'LOGIN_FAILED',
      'entity_type': 'user',
      'created_from': startOfLocalDay('2026-03-21'),
      'created_to': endOfLocalDay('2026-09-22'),
    });
    expect(find.text('فیلترها (فعال)'), findsOneWidget);
    expect(find.text('رویدادی با این مشخصات پیدا نشد.'), findsOneWidget);

    await tapOn(tester, button('حذف فیلترها'));
    expect(app.last('GET /audit-logs').query, {'page': '1'});
    expect(textOf(tester, from.at(0)), isEmpty);
    expect(textOf(tester, to.at(1)), isEmpty);
    expect(find.text('فیلترها'), findsOneWidget);
    expect(badge('ثبت محموله'), findsOneWidget);
  });

  testWidgets('says so when nothing has been recorded', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/audit-logs',
      routes: {'GET /audit-logs': (request) => ok(pageOf(const <Json>[]))},
    );
    expect(find.text('هنوز رویدادی ثبت نشده است.'), findsOneWidget);
  });

  testWidgets('shows everything about an entry and leads on to its shipment', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/audit-logs',
      routes: {'GET /audit-logs': (request) => ok(pageOf(threeEntries())), ...shipmentRoutes()},
    );
    await tapOn(tester, find.byTooltip('نمایش جزئیات رویداد').first);
    expect(inDialog(find.text('ثبت محموله')), findsOneWidget);
    expect(inDialog(find.textContaining('armin.operator')), findsOneWidget);
    expect(inDialog(find.text('SHIPMENT_CREATED')), findsOneWidget);
    expect(inDialog(find.text('محموله')), findsOneWidget);
    expect(inDialog(find.text('s1')), findsOneWidget);
    expect(inDialog(find.text('203.0.113.7')), findsOneWidget);
    expect(inDialog(find.text('req-a1')), findsOneWidget);
    expect(inDialog(find.text('جزئیات')), findsOneWidget);
    expect(inDialog(find.textContaining('"tracking_code_type": "AUTO"')), findsOneWidget);
    // Looking at an entry asks the server nothing.
    expect(app.requests, unorderedEquals(['GET /auth/me', 'GET /audit-logs']));

    await tapOn(tester, button('مشاهدهٔ محموله'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(code), findsOneWidget);
    expect(app.requests, contains('GET /shipments/s1'));
  });

  testWidgets('an entry without user, address or shipment shows what there is', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/audit-logs',
      routes: {'GET /audit-logs': (request) => ok(pageOf(threeEntries()))},
    );
    // A tap on the row opens the entry as well.
    await tapOn(tester, badge('ورود ناموفق'));
    expect(inDialog(find.text('ورود ناموفق')), findsOneWidget);
    expect(inDialog(find.text('بدون کاربر (مشتری یا سامانه)')), findsOneWidget);
    expect(inDialog(find.text('LOGIN_FAILED')), findsOneWidget);
    expect(inDialog(find.text('کاربر')), findsNWidgets(2));
    expect(inDialog(find.text('شناسهٔ موجودیت')), findsNothing);
    expect(inDialog(find.text('نشانی IP')), findsNothing);
    expect(inDialog(find.text('req-a2')), findsOneWidget);
    expect(inDialog(find.textContaining('"reason": "unknown_user"')), findsOneWidget);
    expect(button('مشاهدهٔ محموله'), findsNothing);
    await tapOn(tester, button('بستن'));
    expect(find.byType(AlertDialog), findsNothing);

    // Nothing besides the facts: no heading for details that do not exist.
    await tapOn(tester, find.text('gadget'));
    expect(inDialog(find.text('SOMETHING_NEW')), findsNWidgets(2));
    expect(inDialog(find.text('g-17')), findsOneWidget);
    expect(inDialog(find.text('جزئیات')), findsNothing);
    expect(button('مشاهدهٔ محموله'), findsNothing);
  });

  testWidgets('who may not see shipments is not led to one', (tester) async {
    await pumpApp(
      tester,
      auth: authPayload('1', const {
        'permissions': <String>['audit_log:view'],
      }),
      location: '/audit-logs',
      routes: {'GET /audit-logs': (request) => ok(pageOf(threeEntries()))},
    );
    await tapOn(tester, find.byTooltip('نمایش جزئیات رویداد').first);
    expect(inDialog(find.text('s1')), findsOneWidget);
    expect(button('مشاهدهٔ محموله'), findsNothing);
    expect(button('بستن'), findsOneWidget);
  });

  testWidgets('on a phone the entries are cards and the details fit the screen', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/audit-logs',
      size: phoneSize,
      routes: {'GET /audit-logs': (request) => ok(pageOf(threeEntries())), ...shipmentRoutes()},
    );
    expect(find.byType(DataTable), findsNothing);
    expect(badge('ورود ناموفق'), findsOneWidget);
    await tapOn(tester, find.text('فیلترها'));
    expect(fieldShell('از تاریخ'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tapOn(tester, find.byTooltip('نمایش جزئیات رویداد').first);
    expect(inDialog(find.text('SHIPMENT_CREATED')), findsOneWidget);
    expect(inDialog(find.textContaining('"tracking_code_type": "AUTO"')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tapOn(tester, button('مشاهدهٔ محموله'));
    expect(find.text(code), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
