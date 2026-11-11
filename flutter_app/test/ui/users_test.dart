import 'package:armin_transport/core/api/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

const String kavir = 'باربری کویر (KAVIR) - غیرفعال';
const String shargh = 'ترابر شرق (SHARGH)';

List<Json> twoCompanies() => [companyJson(), companyJson(id: 'c2', name: 'باربری کویر', code: 'KAVIR', active: false)];

Json reza({bool active = true, String companyId = 'c1'}) =>
    userJson(id: 'u5', username: 'reza.k', fullName: 'رضا کریمی', active: active, companyId: companyId);

/// An administrator other than the one who is signed in.
Json otherAdmin() => userJson(
  id: 'u7',
  username: 'root.admin',
  fullName: 'مدیر ارشد',
  role: 'SUPER_ADMIN',
  companyId: null,
  lastLogin: null,
);

void main() {
  testWidgets('lists the accounts and filters them', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/users',
      routes: {
        'GET /users': (request) => ok(pageOf(request.query['q'] == 'هیچ' ? const <Json>[] : [reza(), otherAdmin()])),
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
      },
    );
    expect(find.text('کارمندان شرکت‌ها. هر کارمند فقط به محموله‌های شرکت خود دسترسی دارد.'), findsOneWidget);
    expect(find.text('رضا کریمی'), findsOneWidget);
    expect(find.text('reza.k'), findsOneWidget);
    expect(find.text('ترابر شرق'), findsOneWidget);
    expect(find.text('مدیر ارشد'), findsOneWidget);
    expect(find.text('هنوز وارد نشده'), findsOneWidget);
    expect(badge('مدیر مرکزی'), findsOneWidget);
    expect(app.last('GET /users').query, {'page': '1'});
    // Every company, also those switched off: their employees are still listed.
    expect(app.last('GET /companies').query, {'page': '1', 'per_page': '100'});

    // The accounts of administrators are managed on the server, never through the app.
    expect(find.byTooltip('ویرایش رضا کریمی'), findsOneWidget);
    expect(find.byTooltip('بازنشانی رمز رضا کریمی'), findsOneWidget);
    expect(find.byTooltip('ویرایش مدیر ارشد'), findsNothing);
    expect(find.byTooltip('بازنشانی رمز مدیر ارشد'), findsNothing);

    await tester.enterText(textBox('جست‌وجو'), ' رضا ');
    await choose(tester, 'شرکت', kavir);
    await choose(tester, 'نقش', 'کارمند');
    await choose(tester, 'وضعیت', 'فعال');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(app.last('GET /users').query, {
      'page': '1',
      'q': 'رضا',
      'company_id': 'c2',
      'role': 'EMPLOYEE',
      'is_active': 'true',
    });
    expect(find.text('فیلترها (فعال)'), findsOneWidget);

    await tester.enterText(textBox('جست‌وجو'), 'هیچ');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(find.text('کاربری با این مشخصات پیدا نشد.'), findsOneWidget);

    await tapOn(tester, button('حذف فیلترها'));
    expect(app.last('GET /users').query, {'page': '1'});
    expect(textIn(tester, 'جست‌وجو'), isEmpty);
    expect(find.text('رضا کریمی'), findsOneWidget);
    // The companies were loaded once, for the filter and the forms.
    expect(app.count('GET /companies'), 1);
  });

  testWidgets('creates an employee; what the server refuses is shown at its field', (tester) async {
    final users = [reza()];
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/users',
      routes: {
        'GET /users': (request) => ok(pageOf(users)),
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
        'POST /users': (request) {
          final body = request.json as Map;
          if (body['username'] == 'reza.k') {
            return errorResponse(
              409,
              'username_taken',
              message: 'این نام کاربری قبلاً ثبت شده است.',
              extra: {
                'fields': {
                  'username': ['این نام کاربری قبلاً استفاده شده است.'],
                },
              },
            );
          }
          if ((body['password'] as String).contains('mina')) {
            return errorResponse(
              422,
              'validation_error',
              message: 'اطلاعات واردشده معتبر نیست.',
              extra: {
                'fields': {
                  'password': ['رمز عبور نباید شامل نام کاربری باشد.'],
                },
              },
            );
          }
          users.add(userJson(id: 'u9', username: body['username'] as String, fullName: body['full_name'] as String));
          return ok(users.last, message: 'کارمند با موفقیت ایجاد شد.', status: 201);
        },
      },
    );
    final dialog = find.byType(AlertDialog);
    await tapOn(tester, button('کارمند جدید'));
    expect(inDialog(find.text('کارمند جدید')), findsOneWidget);
    expect(find.text('دست‌کم ۱۰ نویسه؛ نباید شامل نام کاربری باشد.'), findsOneWidget);
    expect(isChecked(tester, 'حساب کاربری فعال است'), isTrue);

    // Nothing typed: the form says what is missing and asks the server nothing.
    await tapOn(tester, button('ایجاد کارمند'));
    expect(find.text('نام را وارد کنید.'), findsOneWidget);
    expect(find.text('نام کاربری را وارد کنید.'), findsOneWidget);
    expect(find.text('شرکت را انتخاب کنید.'), findsOneWidget);
    expect(find.text('رمز عبور را وارد کنید.'), findsOneWidget);
    expect(app.count('POST /users'), 0);

    await tester.enterText(textBox('نام و نام خانوادگی'), ' مینا رستمی ');
    await tester.enterText(textBox('نام کاربری'), 'reza.k');
    await choose(tester, 'شرکت', shargh, within: dialog);
    await tester.enterText(textBox('رمز عبور اولیه'), 'mina.r-12345');
    await tapOn(tester, button('ایجاد کارمند'));
    expect(inDialog(find.text('این نام کاربری قبلاً استفاده شده است.')), findsOneWidget);
    expect(inDialog(find.text('این نام کاربری قبلاً ثبت شده است.')), findsOneWidget);
    expect(find.text('نام را وارد کنید.'), findsNothing);

    // A message for a field the form shows: no summary besides it.
    await tester.enterText(textBox('نام کاربری'), ' mina.r ');
    await tapOn(tester, button('ایجاد کارمند'));
    expect(inDialog(find.text('رمز عبور نباید شامل نام کاربری باشد.')), findsOneWidget);
    expect(find.text('اطلاعات واردشده معتبر نیست.'), findsNothing);
    expect(find.text('این نام کاربری قبلاً استفاده شده است.'), findsNothing);

    // A password is sent as typed: spaces at its ends belong to it.
    await tester.enterText(textBox('رمز عبور اولیه'), ' Sefid-Rood 1405 ');
    await tapOn(tester, button('ایجاد کارمند'));
    expect(dialog, findsNothing);
    expect(app.last('POST /users').json, {
      'full_name': 'مینا رستمی',
      'username': 'mina.r',
      'company_id': 'c1',
      'is_active': true,
      'password': ' Sefid-Rood 1405 ',
    });
    expect(find.text('کارمند با موفقیت ایجاد شد.'), findsOneWidget);
    expect(find.text('مینا رستمی'), findsOneWidget);
    expect(app.count('GET /users'), 2);
  });

  testWidgets('edits an employee: another company, and the account switched off', (tester) async {
    var user = reza();
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/users',
      routes: {
        'GET /users': (request) => ok(pageOf([user])),
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
        'PATCH /users/u5': (request) {
          final body = request.json as Map;
          user = userJson(
            id: 'u5',
            username: body['username'] as String,
            fullName: body['full_name'] as String,
            active: body['is_active'] as bool,
            companyId: body['company_id'] as String,
            companyName: 'باربری کویر',
          );
          return ok(user, message: 'اطلاعات کارمند به‌روزرسانی شد.');
        },
      },
    );
    final dialog = find.byType(AlertDialog);
    expect(badge('فعال'), findsOneWidget);
    await tapOn(tester, find.byTooltip('ویرایش رضا کریمی'));
    expect(inDialog(find.text('ویرایش رضا کریمی')), findsOneWidget);
    expect(textIn(tester, 'نام و نام خانوادگی'), 'رضا کریمی');
    expect(textIn(tester, 'نام کاربری'), 'reza.k');
    // The password of an existing account is changed elsewhere.
    expect(fieldShell('رمز عبور اولیه'), findsNothing);
    expect(isChecked(tester, 'حساب کاربری فعال است'), isTrue);

    await tester.enterText(textBox('نام و نام خانوادگی'), 'رضا کریمی‌نژاد');
    await choose(tester, 'شرکت', kavir, within: dialog);
    await tapOn(tester, checkBox('حساب کاربری فعال است'));
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(dialog, findsNothing);
    expect(app.last('PATCH /users/u5').json, {
      'full_name': 'رضا کریمی‌نژاد',
      'username': 'reza.k',
      'company_id': 'c2',
      'is_active': false,
    });
    expect(find.text('اطلاعات کارمند به‌روزرسانی شد.'), findsOneWidget);
    expect(find.text('رضا کریمی‌نژاد'), findsOneWidget);
    expect(find.text('باربری کویر'), findsOneWidget);
    expect(badge('غیرفعال'), findsOneWidget);
    expect(app.count('GET /users'), 2);
  });

  testWidgets('sets a new password for an employee', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/users',
      routes: {
        'GET /users': (request) => ok(pageOf([reza()])),
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
        'POST /users/u5/reset-password': (request) {
          final password = (request.json as Map)['new_password'] as String;
          if (password.length < 10) {
            return errorResponse(
              422,
              'validation_error',
              message: 'اطلاعات واردشده معتبر نیست.',
              extra: {
                'fields': {
                  'new_password': ['رمز عبور باید دست‌کم ۱۰ نویسه باشد.'],
                },
              },
            );
          }
          return ok(reza(), message: 'رمز عبور کارمند بازنشانی شد و نشست‌های قبلی او باطل شدند.');
        },
      },
    );
    await tapOn(tester, find.byTooltip('بازنشانی رمز رضا کریمی'));
    expect(inDialog(find.text('بازنشانی رمز عبور')), findsOneWidget);
    expect(
      find.text('با تغییر رمز، همهٔ نشست‌های فعال «رضا کریمی» بسته می‌شود و باید با رمز جدید وارد شود.'),
      findsOneWidget,
    );
    expect(find.text('دست‌کم ۱۰ نویسه؛ نباید شامل نام کاربری باشد.'), findsOneWidget);

    await tapOn(tester, button('تغییر رمز عبور'));
    expect(find.text('رمز عبور جدید را وارد کنید.'), findsOneWidget);
    expect(app.count('POST /users/u5/reset-password'), 0);

    await tester.enterText(textBox('رمز عبور جدید'), 'kootah');
    await tapOn(tester, button('تغییر رمز عبور'));
    expect(inDialog(find.text('رمز عبور باید دست‌کم ۱۰ نویسه باشد.')), findsOneWidget);
    expect(find.text('اطلاعات واردشده معتبر نیست.'), findsNothing);

    // The enter key sends the form.
    await tester.enterText(textBox('رمز عبور جدید'), 'Sefid-Rood-1405');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.last('POST /users/u5/reset-password').json, {'new_password': 'Sefid-Rood-1405'});
    expect(find.text('رمز عبور کارمند بازنشانی شد و نشست‌های قبلی او باطل شدند.'), findsOneWidget);
    // Nothing the list shows has changed.
    expect(app.count('GET /users'), 1);
  });

  testWidgets('arrives from the list of companies with that company chosen', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/companies',
      routes: {
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
        'GET /users': (request) => ok(pageOf([reza()])),
        'POST /users': (request) => ok(reza(), message: 'کارمند با موفقیت ایجاد شد.', status: 201),
      },
    );
    await tapOn(tester, find.byTooltip('کارمندان باربری کویر'));
    expect(find.text('کارمندان شرکت‌ها. هر کارمند فقط به محموله‌های شرکت خود دسترسی دارد.'), findsOneWidget);
    expect(app.last('GET /users').query, {'page': '1', 'company_id': 'c2'});
    expect(app.count('GET /users'), 1);
    expect(find.text('فیلترها (فعال)'), findsOneWidget);

    // A new employee is meant for the company whose employees are on screen.
    await tapOn(tester, button('کارمند جدید'));
    await tester.enterText(textBox('نام و نام خانوادگی'), 'مینا رستمی');
    await tester.enterText(textBox('نام کاربری'), 'mina.r');
    await tester.enterText(textBox('رمز عبور اولیه'), 'Sefid-Rood-1405');
    await tapOn(tester, checkBox('حساب کاربری فعال است'));
    await tapOn(tester, button('ایجاد کارمند'));
    expect(app.last('POST /users').json, {
      'full_name': 'مینا رستمی',
      'username': 'mina.r',
      'company_id': 'c2',
      'is_active': false,
      'password': 'Sefid-Rood-1405',
    });

    await tapOn(tester, button('حذف فیلترها'));
    expect(app.last('GET /users').query, {'page': '1'});
    expect(find.text('فیلترها'), findsOneWidget);
  });

  testWidgets('without a company there is nobody to employ', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/users',
      routes: {
        'GET /users': (request) => ok(pageOf(const <Json>[])),
        'GET /companies': (request) => ok(pageOf(const <Json>[])),
      },
    );
    expect(find.text('کاربری با این مشخصات پیدا نشد.'), findsOneWidget);
    await tapOn(tester, button('کارمند جدید'));
    expect(inDialog(find.text('ابتدا باید دست‌کم یک شرکت تعریف کنید.')), findsOneWidget);
    expect(button('ایجاد کارمند'), findsNothing);

    await tapOn(tester, button('مدیریت شرکت‌ها'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('هنوز شرکتی تعریف نشده است.'), findsOneWidget);
  });

  testWidgets('the form asks again for the companies when they could not be loaded', (tester) async {
    var failures = 2;
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/users',
      routes: {
        'GET /users': (request) => ok(pageOf([reza()])),
        'GET /companies': (request) {
          if (failures > 0) {
            failures -= 1;
            return errorResponse(503, 'unavailable', message: 'سرور در دسترس نیست.');
          }
          return ok(pageOf(twoCompanies()));
        },
      },
    );
    // The list does not depend on the companies.
    expect(find.text('رضا کریمی'), findsOneWidget);
    expect(find.text('سرور در دسترس نیست.'), findsNothing);

    await tapOn(tester, button('کارمند جدید'));
    expect(inDialog(find.text('سرور در دسترس نیست.')), findsOneWidget);
    expect(fieldShell('نام کاربری'), findsNothing);
    expect(app.count('GET /companies'), 2);

    await tapOn(tester, button('تلاش دوباره'));
    expect(find.text('سرور در دسترس نیست.'), findsNothing);
    expect(fieldShell('نام کاربری'), findsOneWidget);
    expect(app.count('GET /companies'), 3);

    // The page has the companies now as well: the next form opens with them.
    await tapOn(tester, button('انصراف'));
    await tapOn(tester, find.byTooltip('ویرایش رضا کریمی'));
    expect(fieldShell('نام کاربری'), findsOneWidget);
    expect(app.count('GET /companies'), 3);
  });

  testWidgets('offers only what the user may do', (tester) async {
    await pumpApp(
      tester,
      auth: authPayload('1', const {
        'permissions': <String>['user:view', 'user:update'],
      }),
      location: '/users',
      routes: {
        'GET /users': (request) => ok(pageOf([reza()])),
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
      },
    );
    expect(button('کارمند جدید'), findsNothing);
    expect(find.byTooltip('بازنشانی رمز رضا کریمی'), findsNothing);
    await tapOn(tester, find.byTooltip('ویرایش رضا کریمی'));
    // Switching accounts on and off takes a permission of its own.
    expect(fieldShell('نام کاربری'), findsOneWidget);
    expect(checkField('حساب کاربری فعال است'), findsNothing);
  });

  testWidgets('on a phone the accounts are cards and the form fits the screen', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/users',
      size: phoneSize,
      routes: {
        'GET /users': (request) => ok(pageOf([reza(), otherAdmin()])),
        'GET /companies': (request) => ok(pageOf(twoCompanies())),
      },
    );
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('رضا کریمی'), findsOneWidget);
    await tapOn(tester, find.text('فیلترها'));
    expect(fieldShell('نقش'), findsOneWidget);

    await tapOn(tester, button('کارمند جدید'));
    expect(fieldShell('رمز عبور اولیه'), findsOneWidget);
    await tapOn(tester, button('ایجاد کارمند'));
    expect(find.text('شرکت را انتخاب کنید.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
