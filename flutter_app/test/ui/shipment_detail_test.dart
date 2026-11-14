import 'package:armin_transport/core/api/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

const String code = 'ARMN-7K2M-9QXD-4T8B';

/// A server that holds one shipment, `s1`, and answers what its page asks for.
/// Tests add the routes of the changes they make and alter the state in them.
class ShipmentServer {
  Json shipment = shipmentJson();

  List<Json> values = [
    valueJson(fieldJson(required: true), 120),
    // Switched off, but this shipment still holds a value for it.
    valueJson(fieldJson(id: 'f2', key: 'shelf', label: 'شمارهٔ قفسه', type: 'TEXT', active: false), 'B-12'),
    // Switched off and empty: of no interest any more.
    valueJson(fieldJson(id: 'f3', key: 'gate', label: 'کد انبار', type: 'TEXT', active: false), null),
    valueJson(
      fieldJson(
        id: 'f4',
        key: 'kind',
        label: 'نوع بسته‌بندی',
        type: 'SELECT',
        options: [
          {'value': 'pallet', 'label': 'پالت'},
          {'value': 'carton', 'label': 'کارتن'},
        ],
      ),
      'pallet',
      display: 'پالت',
      outdated: true,
    ),
  ];

  List<Json> documents = [
    documentJson(),
    documentJson(id: 'd2', name: 'invoice-2026.xlsx', size: 1536, visible: false),
  ];

  List<Json> history = [
    historyJson(id: 'h2', oldCode: 'ARMN-OLD0-OLD0-OLD0', newCode: code),
    historyJson(newCode: 'ARMN-OLD0-OLD0-OLD0'),
  ];

  Map<String, RouteHandler> routes([Map<String, RouteHandler> changes = const <String, RouteHandler>{}]) => {
    'GET /shipments': (request) => ok(pageOf([shipment])),
    'GET /shipments/s1': (request) => ok(shipment),
    'GET /shipments/s1/product-values': (request) => ok({'items': values}),
    'GET /shipments/s1/documents': (request) => ok(pageOf(documents)),
    'GET /shipments/s1/tracking-history': (request) => ok(pageOf(history)),
    ...changes,
  };
}

/// The box that decides whether the customer sees the document called [name].
Finder visibilityOf(String name) =>
    find.byWidgetPredicate((widget) => widget is Checkbox && widget.semanticLabel == 'نمایش $name به مشتری');

void main() {
  testWidgets('shows a shipment with its goods', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(tester, auth: authPayload(), location: '/shipments/s1', routes: server.routes());
    expect(find.text(code), findsOneWidget);
    expect(find.text('کد خودکار'), findsOneWidget);
    expect(find.text('دو پالت قطعات یدکی'), findsOneWidget);
    expect(find.text('سارا محمدی'), findsWidgets);
    expect(find.text('سندها (۲)'), findsOneWidget);
    expect(find.text('تاریخچهٔ کد رهگیری'), findsOneWidget);
    expect(app.requests, containsAll(['GET /shipments/s1', 'GET /shipments/s1/product-values']));
    expect(app.requests, isNot(contains('GET /shipments/s1/documents')));

    // The goods: numbers in Persian digits, option labels instead of option values.
    expect(find.text('وزن (کیلوگرم)'), findsOneWidget);
    expect(find.text('۱۲۰'), findsOneWidget);
    expect(find.text('پالت'), findsOneWidget);
    expect(find.text('نیازمند بازبینی'), findsOneWidget);
    expect(find.text('B-12'), findsOneWidget);
    expect(find.text('فیلد غیرفعال'), findsOneWidget);
    expect(find.text('کد انبار'), findsNothing);

    // What an employee may not do is not offered.
    expect(button('ویرایش توضیحات'), findsOneWidget);
    expect(button('بایگانی'), findsOneWidget);
    expect(button('خروج از بایگانی'), findsNothing);
  });

  testWidgets('says so when the shipment does not exist', (tester) async {
    await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments/gone',
      routes: {
        'GET /shipments': (request) => ok(pageOf(const <Json>[])),
        'GET /shipments/gone': (request) => errorResponse(404, 'not_found', message: 'محموله پیدا نشد.'),
      },
    );
    expect(find.text('محموله پیدا نشد.'), findsOneWidget);
    expect(button('تلاش دوباره'), findsOneWidget);
    expect(find.byTooltip('بازگشت به فهرست'), findsOneWidget);
  });

  testWidgets('edits the description in a dialog', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'PATCH /shipments/s1': (request) {
          final description = (request.json as Map)['description'] as String?;
          if (description == 'خطا') return errorResponse(409, 'shipment_archived', message: 'محموله بایگانی شده است.');
          server.shipment = shipmentJson(description: description);
          return ok(server.shipment, message: 'توضیحات ذخیره شد.');
        },
      }),
    );
    await tapOn(tester, button('ویرایش توضیحات'));
    final box = inDialog(find.byType(TextField));
    expect(tester.widget<TextField>(box).controller?.text, 'دو پالت قطعات یدکی');

    // A refusal stays in the dialog, with what was typed.
    await tester.enterText(box, 'خطا');
    await tapOn(tester, button('ذخیره'));
    expect(inDialog(find.text('محموله بایگانی شده است.')), findsOneWidget);
    expect(tester.widget<TextField>(box).controller?.text, 'خطا');

    await tester.enterText(box, '  سه پالت  ');
    await tapOn(tester, button('ذخیره'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.last('PATCH /shipments/s1').json, {'description': 'سه پالت'});
    expect(find.text('توضیحات ذخیره شد.'), findsOneWidget);
    expect(find.text('سه پالت'), findsOneWidget);
    expect(app.count('GET /shipments/s1'), 2);

    // An emptied box removes the description.
    await tapOn(tester, button('ویرایش توضیحات'));
    await tester.enterText(inDialog(find.byType(TextField)), '   ');
    await tapOn(tester, button('ذخیره'));
    expect(app.last('PATCH /shipments/s1').json, {'description': null});

    // Cancelling changes nothing.
    await tapOn(tester, button('ویرایش توضیحات'));
    await tapOn(tester, button('انصراف'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.count('PATCH /shipments/s1'), 3);
  });

  testWidgets('archives after a confirmation, and then only shows', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'POST /shipments/s1/archive': (request) {
          server.shipment = shipmentJson(status: 'ARCHIVED');
          return ok(server.shipment, message: 'محموله بایگانی شد.');
        },
      }),
    );
    await tapOn(tester, button('بایگانی'));
    expect(find.text('بایگانی محموله'), findsOneWidget);
    await tapOn(tester, button('انصراف'));
    expect(app.count('POST /shipments/s1/archive'), 0);

    await tapOn(tester, button('بایگانی'));
    await tapOn(tester, button('بایگانی شود'));
    expect(app.count('POST /shipments/s1/archive'), 1);
    expect(find.text('محموله بایگانی شد.'), findsOneWidget);
    expect(find.textContaining('این محموله بایگانی شده است'), findsOneWidget);
    expect(button('ویرایش توضیحات'), findsNothing);
    expect(button('تغییر کد رهگیری'), findsNothing);
    expect(button('بایگانی'), findsNothing);
    expect(button('ویرایش مشخصات'), findsNothing);
    // Ending customer sessions stays possible.
    expect(button('لغو دسترسی مشتریان'), findsOneWidget);

    // Neither can documents be added.
    await tapOn(tester, find.text('سندها (۲)'));
    expect(button('انتخاب فایل‌ها'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('قابل مشاهده'), findsOneWidget);
    expect(find.text('پنهان'), findsOneWidget);
    expect(button('دریافت'), findsNWidgets(2));
  });

  testWidgets('the administrator takes a shipment out of the archive', (tester) async {
    final server = ShipmentServer()..shipment = shipmentJson(status: 'ARCHIVED');
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'GET /companies': (request) => ok(pageOf([companyJson()])),
        'POST /shipments/s1/unarchive': (request) {
          server.shipment = shipmentJson();
          return ok(server.shipment, message: 'محموله از بایگانی خارج شد.');
        },
      }),
    );
    await tapOn(tester, button('خروج از بایگانی'));
    expect(app.count('POST /shipments/s1/unarchive'), 1);
    expect(find.text('محموله از بایگانی خارج شد.'), findsOneWidget);
    expect(button('خروج از بایگانی'), findsNothing);
    expect(button('بایگانی'), findsOneWidget);
  });

  testWidgets('replaces the tracking code with a generated one', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'POST /shipments/s1/tracking-code': (request) {
          server.shipment = shipmentJson(code: 'ARMN-NEW0-NEW0-NEW0');
          return ok(server.shipment, message: 'کد رهگیری تغییر کرد.');
        },
      }),
    );
    await tapOn(tester, button('تغییر کد رهگیری'));
    expect(inDialog(find.textContaining('کد فعلی برای همیشه از کار می‌افتد')), findsOneWidget);
    expect(inDialog(find.text(code)), findsOneWidget);
    // An employee cannot choose the code.
    expect(inDialog(find.byType(TextField)), findsNothing);
    await tapOn(tester, button('تولید کد جدید'));
    expect(app.last('POST /shipments/s1/tracking-code').json, {'generate': true});
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('ARMN-NEW0-NEW0-NEW0'), findsOneWidget);
    expect(find.text(code), findsNothing);
    expect(find.text('کد رهگیری تغییر کرد.'), findsOneWidget);
  });

  testWidgets('the administrator may type the new tracking code', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'GET /companies': (request) => ok(pageOf([companyJson()])),
        'POST /shipments/s1/tracking-code': (request) {
          final wanted = (request.json as Map)['tracking_code'];
          if (wanted == 'ARMN-TAKEN-01') {
            return errorResponse(409, 'tracking_code_taken', message: 'این کد رهگیری قبلاً استفاده شده است.');
          }
          server.shipment = shipmentJson(code: '$wanted', codeType: 'MANUAL');
          return ok(server.shipment, message: 'کد رهگیری تغییر کرد.');
        },
      }),
    );
    await tapOn(tester, button('تغییر کد رهگیری'));
    final box = inDialog(find.byType(TextField));

    await tester.enterText(box, 'ab');
    await tapOn(tester, button('تغییر کد'));
    expect(inDialog(find.textContaining('دست‌کم ۶ نویسه')), findsOneWidget);
    expect(app.count('POST /shipments/s1/tracking-code'), 0);

    await tester.enterText(box, ' armn-taken-01 ');
    await tapOn(tester, button('تغییر کد'));
    expect(app.last('POST /shipments/s1/tracking-code').json, {'tracking_code': 'ARMN-TAKEN-01'});
    expect(inDialog(find.text('این کد رهگیری قبلاً استفاده شده است.')), findsOneWidget);

    await tester.enterText(box, 'ARMN-FREE-0002');
    await tapOn(tester, button('تغییر کد'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('ARMN-FREE-0002'), findsOneWidget);
    expect(find.text('کد دستی'), findsOneWidget);
  });

  testWidgets('copies the tracking code and ends the sessions of customers', (tester) async {
    final copied = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text']);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'POST /shipments/s1/customer-sessions/revoke': (request) =>
            ok({'revoked': 2}, message: 'دسترسی ۲ مشتری لغو شد.'),
      }),
    );
    await tapOn(tester, find.byTooltip('کپی کد رهگیری'));
    expect(copied, [code]);
    expect(find.text('کد رهگیری کپی شد.'), findsOneWidget);

    await tapOn(tester, button('لغو دسترسی مشتریان'));
    await tapOn(tester, button('لغو دسترسی‌ها'));
    expect(app.count('POST /shipments/s1/customer-sessions/revoke'), 1);
    expect(find.text('دسترسی ۲ مشتری لغو شد.'), findsOneWidget);
    // Nothing about the shipment itself changed.
    expect(app.count('GET /shipments/s1'), 1);
  });

  testWidgets('edits the goods', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'PUT /shipments/s1/product-values': (request) {
          final sent = (request.json as Map)['values'] as Map;
          if (sent['weight'] == 9999) {
            return errorResponse(
              422,
              'validation_error',
              message: 'اطلاعات واردشده معتبر نیست.',
              extra: {
                'fields': {
                  'values.weight': ['مقدار نباید بیشتر از ۵۰۰۰ باشد.'],
                },
              },
            );
          }
          server.values = [valueJson(fieldJson(required: true), sent['weight'])];
          return ok({'items': server.values}, message: 'مشخصات کالا ذخیره شد.');
        },
      }),
    );
    await tapOn(tester, button('ویرایش مشخصات'));
    // The form holds the stored values of the fields that are in use.
    expect(textIn(tester, 'وزن (کیلوگرم)'), '120');
    expect(fieldShell('نوع بسته‌بندی'), findsOneWidget);
    expect(fieldShell('شمارهٔ قفسه'), findsNothing);

    await tester.enterText(textBox('وزن (کیلوگرم)'), '');
    await tapOn(tester, button('ذخیرهٔ مشخصات'));
    expect(find.text('وارد کردن این فیلد الزامی است.'), findsOneWidget);
    expect(app.count('PUT /shipments/s1/product-values'), 0);

    await tester.enterText(textBox('وزن (کیلوگرم)'), '9999');
    await tapOn(tester, button('ذخیرهٔ مشخصات'));
    expect(find.text('مقدار نباید بیشتر از ۵۰۰۰ باشد.'), findsOneWidget);

    await tester.enterText(textBox('وزن (کیلوگرم)'), '۲۵۰');
    await choose(tester, 'نوع بسته‌بندی', 'کارتن');
    await tapOn(tester, button('ذخیرهٔ مشخصات'));
    expect(app.last('PUT /shipments/s1/product-values').json, {
      'values': {'weight': 250, 'kind': 'carton'},
    });
    expect(find.text('مشخصات کالا ذخیره شد.'), findsOneWidget);
    // Back to the values, as the server returned them.
    expect(button('ذخیرهٔ مشخصات'), findsNothing);
    expect(find.text('۲۵۰'), findsOneWidget);
    expect(find.text('B-12'), findsNothing);

    // Cancelling an edit keeps them.
    await tapOn(tester, button('ویرایش مشخصات'));
    await tester.enterText(textBox('وزن (کیلوگرم)'), '1');
    await tapOn(tester, button('انصراف'));
    expect(find.text('۲۵۰'), findsOneWidget);
    expect(app.count('PUT /shipments/s1/product-values'), 2);
  });

  group('the documents', () {
    testWidgets('are listed, shown to or hidden from the customer, and downloaded', (tester) async {
      final server = ShipmentServer();
      var refuse = false;
      final app = await pumpApp(
        tester,
        auth: authPayload(),
        location: '/shipments/s1',
        routes: server.routes({
          'PATCH /documents/d1': (request) => refuse
              ? errorResponse(409, 'shipment_archived', message: 'محموله بایگانی شده است.')
              : ok(documentJson(visible: false), message: 'نمایش سند تغییر کرد.'),
          'GET /documents/d1/download': (request) => fileResponse([37, 80, 68, 70], filename: 'waybill-final.pdf'),
          'GET /documents/d2/download': (request) => errorResponse(404, 'document_not_found', message: 'سند پیدا نشد.'),
        }),
      );
      await tapOn(tester, find.text('سندها (۲)'));
      expect(app.last('GET /shipments/s1/documents').query, {'page': '1'});
      expect(find.text('waybill.pdf'), findsOneWidget);
      expect(find.text('invoice-2026.xlsx'), findsOneWidget);
      expect(find.text('۲۰۰ کیلوبایت'), findsOneWidget);
      // An employee may not delete documents.
      expect(button('حذف'), findsNothing);

      expect(tester.widget<Checkbox>(visibilityOf('waybill.pdf')).value, isTrue);
      expect(tester.widget<Checkbox>(visibilityOf('invoice-2026.xlsx')).value, isFalse);
      await tapOn(tester, visibilityOf('waybill.pdf'));
      expect(app.last('PATCH /documents/d1').json, {'is_customer_visible': false});
      expect(tester.widget<Checkbox>(visibilityOf('waybill.pdf')).value, isFalse);
      expect(find.text('نمایش سند تغییر کرد.'), findsOneWidget);

      // A refused change is taken back.
      refuse = true;
      await tapOn(tester, visibilityOf('waybill.pdf'));
      expect(app.last('PATCH /documents/d1').json, {'is_customer_visible': true});
      expect(tester.widget<Checkbox>(visibilityOf('waybill.pdf')).value, isFalse);
      expect(find.text('محموله بایگانی شده است.'), findsOneWidget);

      await tapOn(tester, button('دریافت').first);
      expect(app.files.saved.single.name, 'waybill-final.pdf');
      expect(app.files.saved.single.bytes, [37, 80, 68, 70]);
      expect(app.files.saved.single.mimeType, 'application/pdf');
      expect(find.text('سند ذخیره شد.'), findsOneWidget);

      await tapOn(tester, button('دریافت').last);
      expect(find.text('سند پیدا نشد.'), findsOneWidget);
      expect(app.files.saved, hasLength(1));

      // Leaving the save dialog is not a failure and not a success.
      app.files.saveResult = false;
      await tapOn(tester, button('دریافت').first);
      expect(find.text('سند ذخیره شد.'), findsNothing);
      expect(app.count('GET /documents/d1/download'), 2);
    });

    testWidgets('are uploaded after a check on the device', (tester) async {
      final server = ShipmentServer();
      final app = await pumpApp(
        tester,
        auth: authPayload(),
        location: '/shipments/s1',
        routes: server.routes({
          'POST /shipments/s1/documents': (request) {
            server.documents = [documentJson(id: 'd3', name: 'scan.pdf', size: 4), ...server.documents];
            server.shipment = shipmentJson(documents: 3);
            return ok([server.documents.first], message: '۱ سند بارگذاری شد.', status: 201);
          },
        }),
      );
      await tapOn(tester, find.text('سندها (۲)'));
      expect(find.textContaining('حداکثر ۱۰ فایل، هر فایل تا ۱۰ مگابایت'), findsOneWidget);
      expect(isEnabled(tester, 'بارگذاری'), isFalse);

      app.files.toPick = [
        pickedFile('scan.pdf', [37, 80, 68, 70]),
        pickedFile('tool.exe', [1, 2]),
        pickedFile('empty.pdf', const <int>[]),
      ];
      await tapOn(tester, button('انتخاب فایل‌ها'));
      expect(find.text('scan.pdf'), findsOneWidget);
      expect(find.text('قالب این فایل مجاز نیست.'), findsOneWidget);
      expect(find.text('فایل خالی است.'), findsOneWidget);
      // Nothing is sent while a file is known to be unacceptable.
      expect(isEnabled(tester, 'بارگذاری ۳ فایل'), isFalse);

      // Choosing the same file again does not add it twice.
      await tapOn(tester, button('انتخاب فایل‌ها'));
      expect(find.text('scan.pdf'), findsOneWidget);

      await tapOn(tester, find.byTooltip('حذف tool.exe از فهرست'));
      await tapOn(tester, find.byTooltip('حذف empty.pdf از فهرست'));
      expect(find.text('قالب این فایل مجاز نیست.'), findsNothing);
      await tapOn(tester, button('بارگذاری ۱ فایل'));

      final upload = app.last('POST /shipments/s1/documents');
      expect(upload.headers['content-type'], startsWith('multipart/form-data; boundary='));
      expect(upload.bodyText, contains('name="files"; filename="scan.pdf"'));
      expect(upload.bodyText, contains('%PDF'));
      expect(upload.bodyText, contains('name="customer_visible"\r\n\r\ntrue'));
      expect(find.text('۱ سند بارگذاری شد.'), findsOneWidget);
      expect(app.files.discarded, 1);
      // The selection is empty again; the list and the count of the shipment are up to date.
      expect(isEnabled(tester, 'بارگذاری'), isFalse);
      expect(find.text('scan.pdf'), findsOneWidget);
      expect(find.text('سندها (۳)'), findsOneWidget);
      expect(app.count('GET /shipments/s1/documents'), 2);
      expect(app.count('GET /shipments/s1'), 2);
    });

    testWidgets('that the server refuses are marked in the selection', (tester) async {
      final server = ShipmentServer();
      var answer = 0;
      final app = await pumpApp(
        tester,
        auth: authPayload(),
        location: '/shipments/s1',
        routes: server.routes({
          'POST /shipments/s1/documents': (request) {
            answer += 1;
            return switch (answer) {
              1 => errorResponse(
                422,
                'invalid_file_content',
                message: 'اطلاعات واردشده معتبر نیست.',
                extra: {
                  'fields': {
                    'files.1': ['محتوای فایل با قالب آن سازگار نیست.'],
                  },
                },
              ),
              2 => errorResponse(
                413,
                'file_too_large',
                message: 'حجم فایل بیش از حد مجاز است.',
                extra: {'file_index': 0},
              ),
              _ => errorResponse(503, 'service_unavailable', message: 'سرور در دسترس نیست.'),
            };
          },
        }),
      );
      await tapOn(tester, find.text('سندها (۲)'));
      app.files.toPick = [
        pickedFile('a.pdf', [1]),
        pickedFile('b.png', [2]),
      ];
      await tapOn(tester, button('انتخاب فایل‌ها'));
      // Hidden from the customer this time.
      await tapOn(tester, find.byType(Checkbox).first);

      await tapOn(tester, button('بارگذاری ۲ فایل'));
      expect(app.last('POST /shipments/s1/documents').bodyText, contains('name="customer_visible"\r\n\r\nfalse'));
      expect(find.text('محتوای فایل با قالب آن سازگار نیست.'), findsOneWidget);
      expect(find.textContaining('هیچ فایلی بارگذاری نشد.'), findsOneWidget);
      expect(isEnabled(tester, 'بارگذاری ۲ فایل'), isFalse);
      expect(app.files.discarded, 0);

      await tapOn(tester, find.byTooltip('حذف b.png از فهرست'));
      await tapOn(tester, button('بارگذاری ۱ فایل'));
      expect(find.text('حجم فایل بیش از حد مجاز است.'), findsOneWidget);

      // A failure that is not about a file leaves the selection ready for another attempt.
      await tapOn(tester, find.byTooltip('حذف a.pdf از فهرست'));
      app.files.toPick = [
        pickedFile('c.pdf', [3]),
      ];
      await tapOn(tester, button('انتخاب فایل‌ها'));
      await tapOn(tester, button('بارگذاری ۱ فایل'));
      expect(find.text('سرور در دسترس نیست.'), findsOneWidget);
      expect(isEnabled(tester, 'بارگذاری ۱ فایل'), isTrue);
      expect(app.count('POST /shipments/s1/documents'), 3);
    });

    testWidgets('are deleted by the administrator after a confirmation', (tester) async {
      final server = ShipmentServer();
      final app = await pumpApp(
        tester,
        auth: adminAuthPayload(),
        location: '/shipments/s1',
        routes: server.routes({
          'GET /companies': (request) => ok(pageOf([companyJson()])),
          'DELETE /documents/d1': (request) {
            server.documents = [server.documents.last];
            server.shipment = shipmentJson(documents: 1);
            return ok(null, message: 'سند حذف شد.');
          },
        }),
      );
      await tapOn(tester, find.text('سندها (۲)'));
      await tapOn(tester, button('حذف').first);
      expect(find.textContaining('سند «waybill.pdf» برای همیشه حذف می‌شود'), findsOneWidget);
      await tapOn(tester, button('انصراف'));
      expect(app.count('DELETE /documents/d1'), 0);

      await tapOn(tester, button('حذف').first);
      await tapOn(tester, button('حذف شود'));
      expect(app.count('DELETE /documents/d1'), 1);
      expect(find.text('سند حذف شد.'), findsOneWidget);
      expect(find.text('waybill.pdf'), findsNothing);
      expect(find.text('invoice-2026.xlsx'), findsOneWidget);
      expect(find.text('سندها (۱)'), findsOneWidget);
    });
  });

  testWidgets('shows the history of the tracking code', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(tester, auth: authPayload(), location: '/shipments/s1', routes: server.routes());
    await tapOn(tester, find.text('تاریخچهٔ کد رهگیری'));
    expect(app.last('GET /shipments/s1/tracking-history').query, {'page': '1'});
    expect(find.text('— (ثبت اولیه)'), findsOneWidget);
    expect(find.text('ARMN-OLD0-OLD0-OLD0'), findsNWidgets(2));
    // The chosen tab stays open; the goods are loaded again when their tab is chosen again.
    await tapOn(tester, find.text('مشخصات کالا'));
    expect(app.count('GET /shipments/s1/product-values'), 2);
  });

  testWidgets('shows only the parts the user may see', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      auth: authPayload('1', const {
        'permissions': <String>['shipment:view', 'document:view'],
      }),
      location: '/shipments/s1',
      routes: server.routes(),
    );
    expect(find.text('مشخصات کالا'), findsNothing);
    expect(find.text('تاریخچهٔ کد رهگیری'), findsNothing);
    // The documents are the first tab now. They can be looked at, nothing else.
    expect(app.count('GET /shipments/s1/documents'), 1);
    expect(find.text('waybill.pdf'), findsOneWidget);
    expect(button('دریافت'), findsNothing);
    expect(button('انتخاب فایل‌ها'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(button('ویرایش توضیحات'), findsNothing);
    expect(button('لغو دسترسی مشتریان'), findsNothing);
  });

  testWidgets('fits a phone', (tester) async {
    final server = ShipmentServer();
    final app = await pumpApp(
      tester,
      size: phoneSize,
      auth: adminAuthPayload(),
      location: '/shipments/s1',
      routes: server.routes({
        'GET /companies': (request) => ok(pageOf([companyJson()])),
      }),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(code), findsOneWidget);
    await tapOn(tester, button('ویرایش مشخصات'));
    expect(tester.takeException(), isNull);
    await tapOn(tester, find.text('سندها (۲)'));
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('waybill.pdf'), findsOneWidget);
    app.files.toPick = [
      pickedFile('a-very-long-name-of-a-scanned-document-2026-11-10.pdf', [1]),
    ];
    await tapOn(tester, button('انتخاب فایل‌ها'));
    expect(tester.takeException(), isNull);
    await tapOn(tester, find.text('تاریخچهٔ کد رهگیری'));
    expect(find.text('— (ثبت اولیه)'), findsOneWidget);
    await tapOn(tester, button('تغییر کد رهگیری'));
    expect(inDialog(find.byType(TextField)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
