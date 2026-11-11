import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

const String code = 'ARMN-7K2M-9QXD-4T8B';

/// Where the portal asks for what the access `tok-1` may see.
const String access = '/customer/access/tok-1';

const String notFound = 'محموله‌ای با این کد رهگیری یافت نشد. کد را بررسی کنید و دوباره تلاش کنید.';
const String accessOver = 'مهلت مشاهدهٔ این محموله تمام شده یا پیوند نامعتبر است. لطفاً دوباره کد رهگیری را وارد کنید.';
const String backAtTheForm = 'نشست مشاهدهٔ محموله به پایان رسیده است. برای ادامه، کد رهگیری را دوباره وارد کنید.';

/// A server on which the code [code] leads to a shipment with two documents.
/// Tests add what else they need and replace what is to go wrong.
Map<String, RouteHandler> portal([Map<String, RouteHandler> more = const <String, RouteHandler>{}]) => {
  'POST /customer/lookup': (request) => (request.json as Map)['tracking_code'] == code
      ? ok({'access_token': 'tok-1', 'expires_at': '2026-11-10T09:00:00Z', 'expires_in': 900}, message: 'محموله یافت شد.')
      : errorResponse(404, 'tracking_code_not_found', message: notFound),
  'GET $access/shipment': (request) => ok(customerShipmentJson()),
  'GET $access/documents': (request) => ok(
    pageOf([customerDocumentJson(), customerDocumentJson(id: 'd2', name: 'invoice-2026.xlsx', size: 1536)]),
  ),
  'POST $access/revoke': (request) => ok(null, message: 'نشست شما پایان یافت.'),
  ...more,
};

/// The box for the tracking code: the only text box of the form.
final Finder codeBox = find.byType(TextField);

String typedCode(WidgetTester tester) => tester.widget<TextField>(codeBox).controller?.text ?? '';

/// Types [typed] into the form and sends it.
Future<void> lookUp(WidgetTester tester, [String typed = code]) async {
  await tester.enterText(codeBox, typed);
  await tapOn(tester, button('رهگیری'));
}

/// Closes the app and gives it a moment for what it still has to tell the server.
Future<void> closeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
}

/// A test of the portal, which ends by closing the app.
///
/// When the screen goes away while a shipment is shown, the app tells the server that the access is no longer
/// needed. That request has to be on its way before the test framework checks that nothing is left under way,
/// which it does right after the body of a test.
void portalTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (tester) async {
    await body(tester);
    await closeApp(tester);
  });
}

void main() {
  portalTest('asks for a code before it asks the server', (tester) async {
    final app = await pumpApp(tester, routes: portal());
    expect(find.text('رهگیری محموله'), findsOneWidget);
    await tapOn(tester, button('رهگیری'));
    expect(find.text('کد رهگیری را وارد کنید.'), findsOneWidget);

    // Spaces are no code either.
    await lookUp(tester, '   ');
    expect(find.text('کد رهگیری را وارد کنید.'), findsOneWidget);
    expect(typedCode(tester), isEmpty);
    expect(app.requests, isEmpty);
  });

  portalTest('a code that leads nowhere says so and stays for correction', (tester) async {
    final app = await pumpApp(tester, routes: portal());
    await lookUp(tester, ' armn-0000-0000-0000 ');
    expect(find.text(notFound), findsOneWidget);
    // Sent, and left in the box, in the shape in which codes are stored.
    expect(app.last('POST /customer/lookup').json, {'tracking_code': 'ARMN-0000-0000-0000'});
    expect(typedCode(tester), 'ARMN-0000-0000-0000');
    expect(isEnabled(tester, 'رهگیری'), isTrue);
    expect(find.text('رهگیری محموله'), findsOneWidget);

    // The enter key sends the form as well; the message of the last attempt is gone.
    await tester.enterText(codeBox, code.toLowerCase());
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text(notFound), findsNothing);
    expect(find.text(code), findsOneWidget);
    expect(app.count('POST /customer/lookup'), 2);
  });

  portalTest('shows what the company shares about the shipment', (tester) async {
    final app = await pumpApp(tester, routes: portal());
    // Typed the way people type: small letters, spaces, a digit of the Persian keyboard.
    await lookUp(tester, ' armn-7k2m-۹qxd-4t8b ');
    expect(app.last('POST /customer/lookup').json, {'tracking_code': code});

    expect(find.text(code), findsOneWidget);
    expect(badge('فعال'), findsOneWidget);
    expect(find.text('ترابر شرق'), findsOneWidget);
    expect(find.text('دو پالت قطعات یدکی'), findsOneWidget);
    expect(find.textContaining('تا ساعت ${formatTime('2026-11-10T09:00:00Z')} در دسترس است'), findsOneWidget);
    // The form is gone, and with it the way to another server.
    expect(find.text('رهگیری محموله'), findsNothing);
    expect(find.text('سرور:'), findsNothing);

    // The goods: numbers in Persian digits, yes and no in words.
    expect(find.text('وزن (کیلوگرم)'), findsOneWidget);
    expect(find.text(formatNumber(1250)), findsOneWidget);
    expect(find.text('پالت'), findsOneWidget);
    expect(find.text('بله'), findsOneWidget);

    // The documents the company lets the customer see.
    expect(find.text('waybill.pdf'), findsOneWidget);
    expect(find.text('invoice-2026.xlsx'), findsOneWidget);
    expect(find.text(formatFileSize(204800)), findsOneWidget);
    expect(button('دریافت'), findsNWidgets(2));
    expect(app.last('GET $access/documents').query, {'page': '1', 'per_page': '20'});

    // The portal is open to everyone: none of its requests carries a token of the staff.
    expect(app.calls, hasLength(3));
    expect(app.calls.where((call) => call.authorization != null), isEmpty);
  });

  portalTest('says so when there are neither goods nor documents to show', (tester) async {
    await pumpApp(
      tester,
      routes: portal({
        'GET $access/shipment': (request) => ok(
          customerShipmentJson(status: 'ARCHIVED', description: null, documents: 0, details: const <Json>[]),
        ),
        'GET $access/documents': (request) => ok(pageOf(const <Json>[])),
      }),
    );
    await lookUp(tester);
    expect(find.text(code), findsOneWidget);
    expect(badge('بایگانی‌شده'), findsOneWidget);
    expect(find.text('مشخصاتی برای نمایش ثبت نشده است.'), findsOneWidget);
    expect(find.text('سندی برای این محموله در دسترس نیست.'), findsOneWidget);
    // Nothing is said about a description that does not exist.
    expect(find.text('توضیحات'), findsNothing);
    expect(find.text('شرکت حمل‌ونقل'), findsOneWidget);
  });

  portalTest('saves a document on the device', (tester) async {
    final app = await pumpApp(
      tester,
      routes: portal({
        'GET $access/documents/d1/download': (request) => fileResponse([37, 80, 68, 70], filename: 'waybill.pdf'),
        'GET $access/documents/d2/download': (request) =>
            errorResponse(404, 'document_not_found', message: 'سند موردنظر یافت نشد.'),
      }),
    );
    await lookUp(tester);
    await tapOn(tester, button('دریافت').first);
    expect(app.files.saved.single.name, 'waybill.pdf');
    expect(app.files.saved.single.bytes, [37, 80, 68, 70]);
    expect(app.files.saved.single.mimeType, 'application/pdf');
    expect(find.text('سند ذخیره شد.'), findsOneWidget);
    expect(app.last('GET $access/documents/d1/download').authorization, isNull);

    // The dialog for the place was closed without choosing one: nothing is claimed.
    app.files.saveResult = false;
    await tapOn(tester, button('دریافت').first);
    expect(app.count('GET $access/documents/d1/download'), 2);
    expect(app.files.saved, hasLength(1));
    expect(find.text('سند ذخیره شد.'), findsNothing);

    // A document that the company has withdrawn meanwhile: the shipment stays on screen.
    await tapOn(tester, button('دریافت').last);
    expect(find.text('سند موردنظر یافت نشد.'), findsOneWidget);
    expect(find.text(code), findsOneWidget);
    expect(isEnabled(tester, 'پایان و جست‌وجوی کد دیگر'), isTrue);
  });

  portalTest('when the access has run out the visitor is back at the form and told why', (tester) async {
    final app = await pumpApp(
      tester,
      routes: portal({
        'GET $access/documents/d1/download': (request) =>
            errorResponse(401, 'customer_session_invalid', message: accessOver),
      }),
    );
    await lookUp(tester);
    await tapOn(tester, button('دریافت').first);
    expect(find.text('رهگیری محموله'), findsOneWidget);
    expect(find.text(backAtTheForm), findsOneWidget);
    expect(find.text(code), findsNothing);
    expect(typedCode(tester), isEmpty);
    // The access is forgotten: there is nothing left to give up.
    expect(app.count('POST $access/revoke'), 0);

    // The notice makes way for what the next attempt has to say.
    await lookUp(tester, 'ARMN-0000-0000-0000');
    expect(find.text(notFound), findsOneWidget);
    expect(find.text(backAtTheForm), findsNothing);
  });

  portalTest('an access that is refused at once leads back to the form', (tester) async {
    await pumpApp(
      tester,
      routes: portal({
        'GET $access/shipment': (request) => errorResponse(401, 'customer_session_invalid', message: accessOver),
      }),
    );
    await lookUp(tester);
    expect(find.text('رهگیری محموله'), findsOneWidget);
    expect(find.text(backAtTheForm), findsOneWidget);
    expect(typedCode(tester), isEmpty);
  });

  portalTest('a shipment that cannot be loaded offers a retry', (tester) async {
    var down = true;
    final app = await pumpApp(
      tester,
      routes: portal({
        'GET $access/shipment': (request) =>
            down ? errorResponse(503, 'unavailable', message: 'سرور در دسترس نیست.') : ok(customerShipmentJson()),
      }),
    );
    await lookUp(tester);
    expect(find.text('سرور در دسترس نیست.'), findsOneWidget);
    expect(find.text(code), findsNothing);

    down = false;
    await tapOn(tester, button('تلاش دوباره'));
    expect(find.text(code), findsOneWidget);
    // The same access: the code was not asked for again.
    expect(app.count('POST /customer/lookup'), 1);
    expect(app.count('GET $access/shipment'), 2);
  });

  portalTest('finishing gives the access up and makes room for another code', (tester) async {
    var lookups = 0;
    final app = await pumpApp(
      tester,
      routes: portal({
        // Every lookup is an access of its own.
        'POST /customer/lookup': (request) {
          lookups += 1;
          return ok({'access_token': 'tok-$lookups', 'expires_at': '2026-11-10T09:00:00Z'});
        },
        'GET /customer/access/tok-2/shipment': (request) => ok(customerShipmentJson(code: 'ARMN-22AA-33BB-44CC')),
        'GET /customer/access/tok-2/documents': (request) => ok(pageOf(const <Json>[])),
      }),
    );
    await lookUp(tester);
    expect(find.text(code), findsOneWidget);

    await tapOn(tester, button('پایان و جست‌وجوی کد دیگر'));
    expect(app.count('POST $access/revoke'), 1);
    expect(find.text('رهگیری محموله'), findsOneWidget);
    expect(find.text(code), findsNothing);
    expect(typedCode(tester), isEmpty);
    // Nothing went wrong, so there is nothing to explain.
    expect(find.text(backAtTheForm), findsNothing);

    await lookUp(tester, 'armn-22aa-33bb-44cc');
    expect(find.text('ARMN-22AA-33BB-44CC'), findsOneWidget);
    expect(find.text('سندی برای این محموله در دسترس نیست.'), findsOneWidget);
    expect(app.count('GET /customer/access/tok-2/shipment'), 1);
    expect(app.count('GET $access/shipment'), 1);
  });

  portalTest('leaving the screen gives the access up', (tester) async {
    final app = await pumpApp(tester, routes: portal());
    await lookUp(tester);
    expect(find.text(code), findsOneWidget);
    expect(app.count('POST $access/revoke'), 0);

    await tapOn(tester, button('ورود کارکنان'));
    // The request leaves when the screen is gone, behind the back of the visitor: give it a moment.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(code), findsNothing);
    expect(app.count('POST $access/revoke'), 1);
    expect(app.last('POST $access/revoke').authorization, isNull);
  });

  portalTest('closing the app gives the access up', (tester) async {
    final app = await pumpApp(tester, routes: portal());
    await lookUp(tester);
    await closeApp(tester);
    expect(app.count('POST $access/revoke'), 1);
  });

  portalTest('a member of the staff who tries the portal stays signed in', (tester) async {
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/track',
      routes: portal({
        'GET $access/documents': (request) => ok(pageOf([customerDocumentJson()])),
        'GET $access/documents/d1/download': (request) =>
            errorResponse(401, 'customer_session_invalid', message: accessOver),
        'GET /dashboard/summary': (request) => ok(dashboardJson()),
      }),
    );
    // The way back to the panel takes the place of the way to the login screen.
    expect(button('ورود کارکنان'), findsNothing);
    expect(button('بازگشت به پنل'), findsOneWidget);

    await lookUp(tester);
    expect(find.text(code), findsOneWidget);
    // The portal answers the code, not the person: the token of the staff stays out of it.
    expect(app.last('POST /customer/lookup').authorization, isNull);
    expect(app.last('GET $access/shipment').authorization, isNull);

    // The access of the customer runs out. That is no reason to end the session of the staff.
    await tapOn(tester, button('دریافت'));
    expect(find.text(backAtTheForm), findsOneWidget);
    expect(app.session.isSignedIn, isTrue);
    expect(app.requests, isNot(contains('POST /auth/refresh')));

    await tapOn(tester, button('بازگشت به پنل'));
    expect(find.text('رهگیری محموله'), findsNothing);
    expect(app.requests, contains('GET /dashboard/summary'));
    expect(app.last('GET /dashboard/summary').authorization, 'Bearer access-1');
  });

  portalTest('on a phone the shipment and its documents fit the screen', (tester) async {
    final app = await pumpApp(
      tester,
      size: phoneSize,
      routes: portal({
        'GET $access/shipment': (request) => ok(
          customerShipmentJson(
            description: 'دو پالت قطعات یدکی برای کارگاه مرکزی، تحویل در انبار شمارهٔ سه پس از هماهنگی تلفنی با مسئول انبار',
          ),
        ),
        'GET $access/documents': (request) => ok(
          pageOf([
            customerDocumentJson(name: 'barnameh-va-surat-jalase-tahvil-anbar-markazi-noskhe-nahayi-1405.pdf'),
            customerDocumentJson(id: 'd2', name: 'invoice-2026.xlsx', size: 1536),
          ]),
        ),
        'GET $access/documents/d2/download': (request) => fileResponse([1, 2, 3], filename: 'invoice-2026.xlsx'),
      }),
    );
    expect(tester.takeException(), isNull);
    await lookUp(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(code), findsOneWidget);
    expect(find.textContaining('barnameh-va-surat-jalase'), findsOneWidget);

    await tapOn(tester, button('دریافت').last);
    expect(app.files.saved.single.name, 'invoice-2026.xlsx');
    expect(tester.takeException(), isNull);

    await tapOn(tester, button('پایان و جست‌وجوی کد دیگر'));
    expect(find.text('رهگیری محموله'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
