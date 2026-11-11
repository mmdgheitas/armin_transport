import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

const String pageDescription =
    'شرکت‌های حمل‌ونقلی که از سامانه استفاده می‌کنند. داده‌های هر شرکت از شرکت‌های دیگر جداست.';

List<Json> twoCompanies() => [companyJson(), companyJson(id: 'c2', name: 'باربری کویر', code: 'KAVIR', active: false)];

void main() {
  testWidgets('lists the companies and filters them', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/companies',
      routes: {
        'GET /companies': (request) => ok(pageOf(request.query['q'] == 'هیچ' ? const <Json>[] : twoCompanies())),
      },
    );
    expect(find.text(pageDescription), findsOneWidget);
    expect(find.text('ترابر شرق'), findsOneWidget);
    expect(find.text('SHARGH'), findsOneWidget);
    expect(find.text('باربری کویر'), findsOneWidget);
    expect(find.text('KAVIR'), findsOneWidget);
    expect(badge('فعال'), findsOneWidget);
    expect(badge('غیرفعال'), findsOneWidget);
    expect(find.text('۲ مورد'), findsOneWidget);
    expect(app.requests, unorderedEquals(['GET /auth/me', 'GET /companies']));
    expect(app.last('GET /companies').query, {'page': '1'});

    await tester.enterText(textBox('جست‌وجو'), '  شرق ');
    await choose(tester, 'وضعیت', 'غیرفعال');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(app.last('GET /companies').query, {'page': '1', 'q': 'شرق', 'is_active': 'false'});
    expect(find.text('فیلترها (فعال)'), findsOneWidget);

    // The enter key of the search box applies the filters as well.
    await tester.enterText(textBox('جست‌وجو'), 'هیچ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(app.last('GET /companies').query, {'page': '1', 'q': 'هیچ', 'is_active': 'false'});
    expect(find.text('شرکتی با این مشخصات پیدا نشد.'), findsOneWidget);

    await tapOn(tester, button('حذف فیلترها'));
    expect(app.last('GET /companies').query, {'page': '1'});
    expect(textIn(tester, 'جست‌وجو'), isEmpty);
    expect(find.text('فیلترها'), findsOneWidget);
    expect(find.text('ترابر شرق'), findsOneWidget);
  });

  testWidgets('says so when no company exists yet', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/companies',
      routes: {'GET /companies': (request) => ok(pageOf(const <Json>[]))},
    );
    expect(find.text('هنوز شرکتی تعریف نشده است.'), findsOneWidget);
    expect(button('شرکت جدید'), findsOneWidget);
  });

  testWidgets('creates a company; what the server refuses is shown at its field', (tester) async {
    final companies = [companyJson()];
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/companies',
      routes: {
        'GET /companies': (request) => ok(pageOf(companies)),
        'POST /companies': (request) {
          final body = request.json as Map;
          if (body['company_code'] == 'SHARGH') {
            return errorResponse(
              409,
              'company_code_taken',
              message: 'شرکتی با این کد قبلاً ثبت شده است.',
              extra: {
                'fields': {
                  'company_code': ['این کد شرکت قبلاً استفاده شده است.'],
                },
              },
            );
          }
          companies.add(companyJson(id: 'c9', name: body['name'] as String, code: body['company_code'] as String));
          return ok(companies.last, message: 'شرکت با موفقیت ایجاد شد.', status: 201);
        },
      },
    );
    await tapOn(tester, button('شرکت جدید'));
    expect(inDialog(find.text('شرکت جدید')), findsOneWidget);
    expect(isChecked(tester, 'شرکت فعال است'), isTrue);

    // Nothing typed: the form says what is missing and asks the server nothing.
    await tapOn(tester, button('ایجاد شرکت'));
    expect(find.text('نام شرکت را وارد کنید.'), findsOneWidget);
    expect(find.text('کد شرکت را وارد کنید.'), findsOneWidget);
    expect(app.count('POST /companies'), 0);

    await tester.enterText(textBox('نام شرکت'), '  باربری البرز ');
    await tester.enterText(textBox('کد شرکت'), 'SHARGH');
    await tester.enterText(textBox('تلفن'), '026-5550199');
    await tapOn(tester, button('ایجاد شرکت'));
    // The dialog stays with what was typed, and the field says what is wrong with it.
    expect(inDialog(find.text('این کد شرکت قبلاً استفاده شده است.')), findsOneWidget);
    expect(inDialog(find.text('شرکتی با این کد قبلاً ثبت شده است.')), findsOneWidget);
    expect(find.text('نام شرکت را وارد کنید.'), findsNothing);
    expect(textIn(tester, 'نام شرکت'), '  باربری البرز ');

    await tester.enterText(textBox('کد شرکت'), ' ALBORZ ');
    await tapOn(tester, button('ایجاد شرکت'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.last('POST /companies').json, {
      'name': 'باربری البرز',
      'company_code': 'ALBORZ',
      'phone': '026-5550199',
      'address': null,
      'is_active': true,
    });
    expect(find.text('شرکت با موفقیت ایجاد شد.'), findsOneWidget);
    expect(find.text('باربری البرز'), findsOneWidget);
    expect(find.text('ALBORZ'), findsOneWidget);
    expect(app.count('GET /companies'), 2);

    // Cancelling asks the server nothing.
    await tapOn(tester, button('شرکت جدید'));
    await tester.enterText(textBox('نام شرکت'), 'ناتمام');
    await tapOn(tester, button('انصراف'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.count('POST /companies'), 2);
    expect(app.count('GET /companies'), 2);
  });

  testWidgets('edits a company and tells how much belongs to it', (tester) async {
    var company = companyJson();
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/companies',
      routes: {
        'GET /companies': (request) => ok(pageOf([company])),
        'GET /companies/c1': (request) => ok({...company, 'employee_count': 4, 'shipment_count': 1284}),
        'PATCH /companies/c1': (request) {
          final body = request.json as Map;
          company = {...company, 'name': body['name'], 'is_active': body['is_active']};
          return ok(company, message: 'اطلاعات شرکت به‌روزرسانی شد.');
        },
      },
    );
    await tapOn(tester, find.byTooltip('ویرایش ترابر شرق'));
    expect(inDialog(find.text('ویرایش ترابر شرق')), findsOneWidget);
    expect(
      find.text('${formatNumber(4)} کارمند و ${formatNumber(1284)} محموله برای این شرکت ثبت شده است.'),
      findsOneWidget,
    );
    expect(textIn(tester, 'نام شرکت'), 'ترابر شرق');
    expect(textIn(tester, 'کد شرکت'), 'SHARGH');
    expect(textIn(tester, 'تلفن'), '021-5550100');
    expect(textIn(tester, 'نشانی'), 'تهران، خیابان آزادی');
    expect(isChecked(tester, 'شرکت فعال است'), isTrue);

    await tester.enterText(textBox('نام شرکت'), 'ترابر شرق نو');
    await tester.enterText(textBox('تلفن'), '  ');
    await tapOn(tester, checkBox('شرکت فعال است'));
    expect(isChecked(tester, 'شرکت فعال است'), isFalse);
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.last('PATCH /companies/c1').json, {
      'name': 'ترابر شرق نو',
      'company_code': 'SHARGH',
      'phone': null,
      'address': 'تهران، خیابان آزادی',
      'is_active': false,
    });
    expect(find.text('اطلاعات شرکت به‌روزرسانی شد.'), findsOneWidget);
    expect(find.text('ترابر شرق نو'), findsOneWidget);
    expect(badge('غیرفعال'), findsOneWidget);
    expect(app.count('GET /companies'), 2);
  });

  testWidgets('the form works without the numbers of the company', (tester) async {
    var answers = false;
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/companies',
      routes: {
        'GET /companies': (request) => ok(pageOf([companyJson()])),
        // First no answer at all, then an answer that lacks the numbers.
        'GET /companies/c1': (request) =>
            answers ? ok(companyJson()) : errorResponse(503, 'unavailable', message: 'سرور در دسترس نیست.'),
        'PATCH /companies/c1': (request) => ok(companyJson(), message: 'اطلاعات شرکت به‌روزرسانی شد.'),
      },
    );
    await tapOn(tester, find.byTooltip('ویرایش ترابر شرق'));
    expect(app.count('GET /companies/c1'), 1);
    expect(find.textContaining('برای این شرکت ثبت شده است.'), findsNothing);
    expect(find.text('سرور در دسترس نیست.'), findsNothing);
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(find.text('اطلاعات شرکت به‌روزرسانی شد.'), findsOneWidget);

    // Numbers that the server did not tell are not made up.
    answers = true;
    await tapOn(tester, find.byTooltip('ویرایش ترابر شرق'));
    expect(app.count('GET /companies/c1'), 2);
    expect(textIn(tester, 'نام شرکت'), 'ترابر شرق');
    expect(find.textContaining('برای این شرکت ثبت شده است.'), findsNothing);
  });

  testWidgets('offers only what the user may do', (tester) async {
    // May look at the companies, nothing else.
    await pumpApp(
      tester,
      auth: authPayload('1', const {
        'permissions': <String>['company:view'],
      }),
      location: '/companies',
      routes: {'GET /companies': (request) => ok(pageOf(twoCompanies()))},
    );
    expect(find.text('ترابر شرق'), findsOneWidget);
    expect(button('شرکت جدید'), findsNothing);
    expect(find.byTooltip('ویرایش ترابر شرق'), findsNothing);
    expect(find.byTooltip('کارمندان ترابر شرق'), findsNothing);
    expect(find.text('عملیات'), findsNothing);
  });

  testWidgets('who may not switch companies on and off is not offered that setting', (tester) async {
    final app = await pumpApp(
      tester,
      auth: authPayload('1', const {
        'permissions': <String>['company:view', 'company:update'],
      }),
      location: '/companies',
      routes: {
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
        'GET /companies/c1': (request) => ok(companyJson()),
        'PATCH /companies/c1': (request) => ok(companyJson(), message: 'اطلاعات شرکت به‌روزرسانی شد.'),
      },
    );
    expect(find.text('عملیات'), findsOneWidget);
    await tapOn(tester, find.byTooltip('ویرایش ترابر شرق'));
    expect(checkField('شرکت فعال است'), findsNothing);
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(app.last('PATCH /companies/c1').json, {
      'name': 'ترابر شرق',
      'company_code': 'SHARGH',
      'phone': '021-5550100',
      'address': 'تهران، خیابان آزادی',
    });
  });

  testWidgets('on a phone the companies are cards and the form fits the screen', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/companies',
      size: phoneSize,
      routes: {
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
        'GET /companies/c2': (request) => ok(companyJson(id: 'c2', name: 'باربری کویر', code: 'KAVIR', active: false)),
      },
    );
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('باربری کویر'), findsOneWidget);
    // Folded away on a phone, where the filters would push the list off the screen.
    expect(fieldShell('جست‌وجو'), findsNothing);
    await tapOn(tester, find.text('فیلترها'));
    expect(fieldShell('جست‌وجو'), findsOneWidget);

    await tapOn(tester, find.byTooltip('ویرایش باربری کویر'));
    expect(textIn(tester, 'کد شرکت'), 'KAVIR');
    expect(isChecked(tester, 'شرکت فعال است'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
