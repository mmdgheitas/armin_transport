import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/jalali.dart';
import 'package:armin_transport/core/product_fields.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

const String firstCode = 'ARMN-7K2M-9QXD-4T8B';
const String secondCode = 'ARMN-22AA-33BB-44CC';

List<Json> twoShipments() => [shipmentJson(), shipmentJson(id: 's2', code: secondCode, status: 'ARCHIVED')];

void main() {
  testWidgets('lists the shipments of the company and filters them', (tester) async {
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments',
      routes: {
        'GET /shipments': (request) =>
            ok(pageOf(request.query['q'] == 'هیچ' ? const <Json>[] : twoShipments())),
      },
    );
    expect(find.text('محموله‌های شرکت شما'), findsOneWidget);
    expect(find.text(firstCode), findsOneWidget);
    expect(find.text(secondCode), findsOneWidget);
    expect(find.text('۲ مورد'), findsOneWidget);
    expect(app.requests, unorderedEquals(['GET /auth/me', 'GET /shipments']));
    expect(app.last('GET /shipments').query, {'page': '1'});
    // An employee sees one company only: no filter and no column for it.
    expect(fieldShell('شرکت'), findsNothing);
    expect(find.text('فیلترها'), findsOneWidget);

    await tester.enterText(textBox('جست‌وجو'), '  قطعات ');
    await choose(tester, 'وضعیت', 'بایگانی‌شده');
    await choose(tester, 'نوع کد رهگیری', 'دستی');
    await choose(tester, 'ترتیب', 'قدیمی‌ترین');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(app.last('GET /shipments').query, {
      'page': '1',
      'q': 'قطعات',
      'status': 'ARCHIVED',
      'tracking_code_type': 'MANUAL',
      'sort': 'created_at',
    });
    expect(find.text('فیلترها (فعال)'), findsOneWidget);

    // Nothing matches: the screen says so and offers no "new shipment" in place of the list.
    await tester.enterText(textBox('جست‌وجو'), 'هیچ');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(find.text('محموله‌ای با این مشخصات پیدا نشد.'), findsOneWidget);
    expect(find.text('فیلترها را تغییر دهید یا حذف کنید.'), findsOneWidget);
    expect(button('ثبت محمولهٔ جدید'), findsOneWidget);

    // Clearing keeps the chosen order, which is not a filter.
    await tapOn(tester, button('حذف فیلترها'));
    expect(app.last('GET /shipments').query, {'page': '1', 'sort': 'created_at'});
    expect(textIn(tester, 'جست‌وجو'), isEmpty);
    expect(find.text('فیلترها'), findsOneWidget);
    expect(button('حذف فیلترها'), findsNothing);
    expect(find.text(firstCode), findsOneWidget);
  });

  testWidgets('pages through a long list', (tester) async {
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments',
      routes: {
        'GET /shipments': (request) {
          final page = int.parse(request.query['page'] ?? '1');
          return ok(pageOf([shipmentJson(id: 'p$page', code: 'ARMN-PAGE-000$page')], page: page, total: 45));
        },
      },
    );
    expect(find.text('۴۵ مورد · صفحهٔ ۱ از ۳'), findsOneWidget);
    expect(isEnabled(tester, 'قبلی'), isFalse);
    await tapOn(tester, button('بعدی'));
    expect(app.last('GET /shipments').query, {'page': '2'});
    expect(find.text('ARMN-PAGE-0002'), findsOneWidget);
    expect(find.text('ARMN-PAGE-0001'), findsNothing);
    await tapOn(tester, button('بعدی'));
    expect(find.text('۴۵ مورد · صفحهٔ ۳ از ۳'), findsOneWidget);
    expect(isEnabled(tester, 'بعدی'), isFalse);
    await tapOn(tester, button('قبلی'));
    expect(app.last('GET /shipments').query, {'page': '2'});
  });

  testWidgets('the administrator filters by company', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/shipments',
      routes: {
        'GET /shipments': (request) => ok(pageOf(twoShipments())),
        'GET /companies': (request) => ok(
          pageOf([companyJson(), companyJson(id: 'c2', name: 'باربری کویر', code: 'KAVIR', active: false)]),
        ),
      },
    );
    expect(find.text('محموله‌های همهٔ شرکت‌ها'), findsOneWidget);
    expect(app.last('GET /companies').query, {'page': '1', 'per_page': '100'});

    await choose(tester, 'شرکت', 'باربری کویر (KAVIR) - غیرفعال');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(app.last('GET /shipments').query, {'page': '1', 'company_id': 'c2'});
  });

  testWidgets('date filters cover whole days of the device and refuse half a date', (tester) async {
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments',
      routes: {'GET /shipments': (request) => ok(pageOf(twoShipments()))},
    );
    final from = find.descendant(of: fieldShell('ثبت از تاریخ'), matching: find.byType(TextField));
    final to = find.descendant(of: fieldShell('ثبت تا تاریخ'), matching: find.byType(TextField));

    // A day without month and year is not a date.
    await tester.enterText(from.at(0), '15');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(find.text('تاریخ واردشده کامل یا معتبر نیست.'), findsOneWidget);
    expect(app.count('GET /shipments'), 1);

    await choose(tester, 'ثبت از تاریخ', 'اردیبهشت');
    await tester.enterText(from.at(1), '1405');
    await tester.enterText(to.at(0), '۲۰');
    await choose(tester, 'ثبت تا تاریخ', 'اردیبهشت');
    await tester.enterText(to.at(1), '۱۴۰۵');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(find.text('تاریخ واردشده کامل یا معتبر نیست.'), findsNothing);
    final firstDay = jalaliToIsoDate(1405, 2, 15);
    final lastDay = jalaliToIsoDate(1405, 2, 20);
    expect(firstDay, '2026-05-05');
    expect(app.last('GET /shipments').query, {
      'page': '1',
      'created_from': startOfLocalDay(firstDay),
      'created_to': endOfLocalDay(lastDay),
    });
  });

  testWidgets('opens a shipment from the list; what is changed there shows in the list afterwards', (tester) async {
    var description = 'دو پالت قطعات یدکی';
    Json first() => shipmentJson(description: description);
    Json second() => shipmentJson(id: 's2', code: secondCode, status: 'ARCHIVED', description: 'یک دستگاه ژنراتور');
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments',
      routes: {
        'GET /shipments': (request) => ok(pageOf([first(), second()])),
        'GET /shipments/s1': (request) => ok(first()),
        'GET /shipments/s1/product-values': (request) => ok({'items': const <Json>[]}),
        'PATCH /shipments/s1': (request) {
          description = (request.json as Map)['description'] as String;
          return ok(first(), message: 'توضیحات ذخیره شد.');
        },
        'GET /shipments/s2': (request) => ok(second()),
        'GET /shipments/s2/product-values': (request) => ok({'items': const <Json>[]}),
      },
    );
    await tapOn(tester, find.text(firstCode));
    expect(find.text('جزئیات محموله'), findsWidgets);
    expect(app.requests, contains('GET /shipments/s1'));
    expect(app.count('GET /shipments'), 1);

    await tapOn(tester, button('ویرایش توضیحات'));
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'سه پالت');
    await tapOn(tester, button('ذخیره'));
    // The list lies underneath, out of sight. It is told about the change and loads again.
    expect(app.count('GET /shipments'), 2);

    await tapOn(tester, find.byTooltip('بازگشت به فهرست'));
    expect(find.text('محموله‌های شرکت شما'), findsOneWidget);
    expect(find.text('سه پالت'), findsOneWidget);
    expect(find.text('دو پالت قطعات یدکی'), findsNothing);
    expect(app.count('GET /shipments'), 2);

    // Another shipment is another page, not the last one with new content.
    await tapOn(tester, find.text(secondCode));
    expect(find.textContaining('این محموله بایگانی شده است'), findsOneWidget);
    expect(find.text('یک دستگاه ژنراتور'), findsOneWidget);
    expect(find.text('سه پالت'), findsNothing);
    expect(app.count('GET /shipments'), 2);
  });

  testWidgets('on a phone the list is a column of cards and the filters are folded away', (tester) async {
    await pumpApp(
      tester,
      size: phoneSize,
      auth: authPayload(),
      location: '/shipments',
      routes: {'GET /shipments': (request) => ok(pageOf(twoShipments()))},
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(DataTable), findsNothing);
    expect(find.text(firstCode), findsOneWidget);
    expect(fieldShell('جست‌وجو'), findsNothing);
    await tapOn(tester, find.text('فیلترها'));
    expect(fieldShell('جست‌وجو'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('a new shipment', () {
    testWidgets('is registered by an employee with the goods of the form', (tester) async {
      final app = await pumpApp(
        tester,
        auth: authPayload(),
        location: '/shipments/new',
        routes: {
          'GET /shipments': (request) => ok(pageOf(const <Json>[])),
          'GET /product-fields': (request) => ok(
            pageOf([
              fieldJson(required: true),
              fieldJson(id: 'f2', key: 'fragile', label: 'شکستنی', type: 'BOOLEAN'),
            ]),
          ),
          'POST /shipments': (request) => ok(shipmentJson(id: 's9'), message: 'محموله ثبت شد.', status: 201),
          'GET /shipments/s9': (request) => ok(shipmentJson(id: 's9')),
          'GET /shipments/s9/product-values': (request) => ok({'items': const <Json>[]}),
        },
      );
      expect(find.text('ثبت محمولهٔ جدید'), findsWidgets);
      // An employee cannot choose the code, and belongs to one company.
      expect(find.textContaining('به‌صورت خودکار، یکتا و غیرقابل‌حدس'), findsOneWidget);
      expect(fieldShell('شرکت'), findsNothing);
      expect(app.last('GET /product-fields').query, {'page': '1', 'per_page': '100'});

      // The required goods field is missing: nothing is sent.
      await tapOn(tester, button('ثبت محموله'));
      expect(find.text('وارد کردن این فیلد الزامی است.'), findsOneWidget);
      expect(app.requests, isNot(contains('POST /shipments')));

      await tester.enterText(textBox('توضیحات'), '  سه کارتن لوازم  ');
      await tester.enterText(textBox('وزن (کیلوگرم)'), '۱۲۰');
      await choose(tester, 'شکستنی', 'بله');
      await tapOn(tester, button('ثبت محموله'));
      expect(app.last('POST /shipments').json, {
        'description': 'سه کارتن لوازم',
        'product_values': {'weight': 120, 'fragile': true},
      });
      // The new shipment is opened.
      expect(find.text('محموله ثبت شد.'), findsOneWidget);
      expect(find.text('جزئیات محموله'), findsWidgets);
      expect(app.requests, contains('GET /shipments/s9'));
      // The list was never on screen: it loads when the user gets there.
      expect(app.count('GET /shipments'), 0);
      await tapOn(tester, find.byTooltip('بازگشت به فهرست'));
      expect(app.count('GET /shipments'), 1);
      expect(find.text('محموله‌های شرکت شما'), findsOneWidget);
    });

    testWidgets('shows what the server says about single fields next to them', (tester) async {
      await pumpApp(
        tester,
        auth: authPayload(),
        location: '/shipments/new',
        routes: {
          'GET /shipments': (request) => ok(pageOf(const <Json>[])),
          'GET /product-fields': (request) => ok(pageOf([fieldJson()])),
          'POST /shipments': (request) => errorResponse(
            422,
            'validation_error',
            message: 'اطلاعات واردشده معتبر نیست.',
            extra: {
              'fields': {
                'values.weight': ['مقدار باید دست‌کم ۱ باشد.'],
                'description': ['توضیحات بیش از حد طولانی است.'],
              },
            },
          ),
        },
      );
      await tester.enterText(textBox('وزن (کیلوگرم)'), '0');
      await tapOn(tester, button('ثبت محموله'));
      expect(find.text('مقدار باید دست‌کم ۱ باشد.'), findsOneWidget);
      expect(find.text('توضیحات بیش از حد طولانی است.'), findsOneWidget);
      // Every message found its field: no summary on top of them.
      expect(find.text('اطلاعات واردشده معتبر نیست.'), findsNothing);
      expect(isEnabled(tester, 'ثبت محموله'), isTrue);
    });

    testWidgets('the administrator chooses the company and may type the tracking code', (tester) async {
      var taken = true;
      final app = await pumpApp(
        tester,
        auth: adminAuthPayload(),
        location: '/shipments/new',
        routes: {
          'GET /shipments': (request) => ok(pageOf(const <Json>[])),
          'GET /product-fields': (request) => ok(pageOf(const <Json>[])),
          'GET /companies': (request) => ok(
            pageOf(
              request.query['is_active'] == 'true'
                  ? [companyJson(), companyJson(id: 'c3', name: 'ترابر جنوب', code: 'JONUB')]
                  : [companyJson(), companyJson(id: 'c2', name: 'باربری کویر', code: 'KAVIR', active: false)],
            ),
          ),
          'POST /shipments': (request) {
            if (taken) {
              taken = false;
              return errorResponse(409, 'tracking_code_taken', message: 'این کد رهگیری قبلاً استفاده شده است.');
            }
            return ok(shipmentJson(id: 's9', code: 'ARMN-2026-0002', codeType: 'MANUAL'), status: 201);
          },
          'GET /shipments/s9': (request) => ok(shipmentJson(id: 's9', code: 'ARMN-2026-0002', codeType: 'MANUAL')),
          'GET /shipments/s9/product-values': (request) => ok({'items': const <Json>[]}),
        },
      );
      // Without goods fields the form has one card only.
      expect(find.text('مشخصات کالا'), findsNothing);

      await tapOn(tester, button('ثبت محموله'));
      expect(find.text('شرکت را انتخاب کنید.'), findsOneWidget);
      expect(app.requests, isNot(contains('POST /shipments')));

      // Only active companies are offered.
      await choose(tester, 'شرکت', 'ترابر جنوب (JONUB)');
      expect(find.text('باربری کویر (KAVIR) - غیرفعال'), findsNothing);

      expect(fieldShell('کد رهگیری دستی'), findsNothing);
      await tapOn(tester, button('ورود دستی'));
      await tester.enterText(textBox('کد رهگیری دستی'), ' ab ');
      await tapOn(tester, button('ثبت محموله'));
      // Too short: put into its canonical form, but not sent.
      expect(textIn(tester, 'کد رهگیری دستی'), 'AB');
      expect(app.requests, isNot(contains('POST /shipments')));

      await tester.enterText(textBox('کد رهگیری دستی'), 'armn-2026-0001');
      await tapOn(tester, button('ثبت محموله'));
      expect(app.last('POST /shipments').json, {'company_id': 'c3', 'tracking_code': 'ARMN-2026-0001'});
      // The message belongs to the code and is shown there, once.
      expect(find.text('این کد رهگیری قبلاً استفاده شده است.'), findsOneWidget);

      await tester.enterText(textBox('کد رهگیری دستی'), 'ARMN-2026-0002');
      await tapOn(tester, button('ثبت محموله'));
      expect(find.text('ARMN-2026-0002'), findsOneWidget);
      expect(find.text('کد دستی'), findsOneWidget);
    });

    testWidgets('needs an active company first', (tester) async {
      await pumpApp(
        tester,
        auth: adminAuthPayload(),
        location: '/shipments/new',
        routes: {
          'GET /shipments': (request) => ok(pageOf(const <Json>[])),
          'GET /product-fields': (request) => ok(pageOf([fieldJson()])),
          'GET /companies': (request) => ok(pageOf(const <Json>[])),
        },
      );
      expect(find.textContaining('دست‌کم یک شرکت فعال'), findsOneWidget);
      expect(button('ثبت محموله'), findsNothing);
      expect(button('مدیریت شرکت‌ها'), findsOneWidget);
    });

    testWidgets('fits a phone', (tester) async {
      await pumpApp(
        tester,
        size: phoneSize,
        auth: adminAuthPayload(),
        location: '/shipments/new',
        routes: {
          'GET /shipments': (request) => ok(pageOf(const <Json>[])),
          'GET /companies': (request) => ok(pageOf([companyJson()])),
          'GET /product-fields': (request) => ok(
            pageOf([
              fieldJson(required: true),
              fieldJson(id: 'f2', key: 'loaded_at', label: 'زمان بارگیری', type: 'DATETIME'),
              fieldJson(
                id: 'f3',
                key: 'kind',
                label: 'نوع بسته‌بندی',
                type: 'MULTI_SELECT',
                options: [
                  {'value': 'pallet', 'label': 'پالت'},
                  {'value': 'carton', 'label': 'کارتن'},
                ],
              ),
            ]),
          ),
        },
      );
      expect(tester.takeException(), isNull);
      // The only active company is chosen already.
      expect(find.text('ترابر شرق (SHARGH)'), findsOneWidget);
      await tapOn(tester, button('ورود دستی'));
      expect(fieldShell('کد رهگیری دستی'), findsOneWidget);
      expect(fieldShell('زمان بارگیری'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
