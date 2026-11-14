import 'package:armin_transport/features/profile/profile_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

/// What the page itself shows. The frame around it names the user and the company as well.
Finder onPage(Finder finder) =>
    find.descendant(of: find.byType(ProfilePage), matching: finder);

void main() {
  testWidgets('shows who is signed in', (tester) async {
    await pumpApp(tester, auth: authPayload(), location: '/profile');
    expect(onPage(find.text('سارا محمدی')), findsOneWidget);
    expect(onPage(find.text('armin.operator')), findsOneWidget);
    expect(onPage(find.text('کارمند')), findsOneWidget);
    expect(onPage(find.text('حمل‌ونقل')), findsOneWidget);
    expect(
      find.text('دست‌کم ۱۰ نویسه؛ نباید شامل نام کاربری باشد.'),
      findsOneWidget,
    );
    expect(
      find.text('پس از تغییر رمز، نشست شما در دستگاه‌های دیگر بسته می‌شود.'),
      findsOneWidget,
    );
  });

  testWidgets('the central administrator belongs to no company', (
    tester,
  ) async {
    await pumpApp(tester, auth: adminAuthPayload(), location: '/profile');
    expect(onPage(find.text('مدیر سامانه')), findsOneWidget);
    expect(onPage(find.text('مدیر مرکزی')), findsOneWidget);
    expect(onPage(find.text('نقش')), findsOneWidget);
    expect(onPage(find.text('شرکت')), findsNothing);
  });

  testWidgets('changes the password and goes on with the new tokens', (
    tester,
  ) async {
    final app = await pumpApp(
      tester,
      auth: authPayload(),
      location: '/profile',
      routes: {
        'POST /auth/change-password': (request) {
          final body = request.json as Map;
          if (body['current_password'] != 'Ghadimi-1404') {
            return errorResponse(
              422,
              'invalid_current_password',
              message: 'اطلاعات واردشده معتبر نیست.',
              extra: {
                'fields': {
                  'current_password': ['رمز عبور فعلی نادرست است.'],
                },
              },
            );
          }
          // Every other session of the user is closed; this one gets new tokens.
          return ok(authPayload('2'), message: 'رمز عبور با موفقیت تغییر کرد.');
        },
        'GET /dashboard/summary': (request) => ok(dashboardJson()),
      },
    );
    // Nothing typed: the form says what is missing and asks the server nothing.
    await tapOn(tester, button('تغییر رمز عبور'));
    expect(find.text('رمز عبور فعلی را وارد کنید.'), findsOneWidget);
    expect(find.text('رمز عبور جدید را وارد کنید.'), findsOneWidget);
    expect(find.text('رمز عبور جدید را دوباره وارد کنید.'), findsOneWidget);

    await tester.enterText(textBox('رمز عبور فعلی'), 'eshtebah');
    await tester.enterText(textBox('رمز عبور جدید'), 'Sefid-Rood-1405');
    await tester.enterText(textBox('تکرار رمز عبور جدید'), 'Sefid-Rood-1406');
    await tapOn(tester, button('تغییر رمز عبور'));
    expect(find.text('تکرار رمز عبور با رمز جدید یکسان نیست.'), findsOneWidget);
    expect(find.text('رمز عبور فعلی را وارد کنید.'), findsNothing);
    expect(app.count('POST /auth/change-password'), 0);

    await tester.enterText(textBox('تکرار رمز عبور جدید'), 'Sefid-Rood-1405');
    await tapOn(tester, button('تغییر رمز عبور'));
    // What the server says about a box is shown at that box, without a summary besides it.
    expect(find.text('رمز عبور فعلی نادرست است.'), findsOneWidget);
    expect(find.text('اطلاعات واردشده معتبر نیست.'), findsNothing);
    // What was typed stays for the next attempt, and the session is as it was.
    expect(textIn(tester, 'رمز عبور جدید'), 'Sefid-Rood-1405');
    expect(app.session.auth?.accessToken, 'access-1');

    // The enter key in the last box sends the form.
    await tester.enterText(textBox('رمز عبور فعلی'), 'Ghadimi-1404');
    await tester.enterText(textBox('تکرار رمز عبور جدید'), 'Sefid-Rood-1405');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.last('POST /auth/change-password').json, {
      'current_password': 'Ghadimi-1404',
      'new_password': 'Sefid-Rood-1405',
    });
    expect(
      app.last('POST /auth/change-password').authorization,
      'Bearer access-1',
    );
    expect(find.text('رمز عبور با موفقیت تغییر کرد.'), findsOneWidget);
    expect(find.text('رمز عبور فعلی نادرست است.'), findsNothing);
    expect(textIn(tester, 'رمز عبور فعلی'), isEmpty);
    expect(textIn(tester, 'رمز عبور جدید'), isEmpty);
    expect(textIn(tester, 'تکرار رمز عبور جدید'), isEmpty);

    // The user stays signed in, and the next request carries the new token.
    expect(app.session.isSignedIn, isTrue);
    expect(app.session.auth?.accessToken, 'access-2');
    await tapOn(tester, find.text('داشبورد'));
    expect(app.last('GET /dashboard/summary').authorization, 'Bearer access-2');
  });

  testWidgets('a password is hidden until the eye is pressed', (tester) async {
    await pumpApp(tester, auth: authPayload(), location: '/profile');
    final box = textBox('رمز عبور فعلی');
    await tester.enterText(box, 'Ghadimi-1404');
    expect(tester.widget<TextField>(box).obscureText, isTrue);
    await tapOn(tester, find.byTooltip('نمایش رمز').first);
    expect(tester.widget<TextField>(box).obscureText, isFalse);
    // Only this box: the others stay hidden.
    expect(
      tester.widget<TextField>(textBox('رمز عبور جدید')).obscureText,
      isTrue,
    );
    await tapOn(tester, find.byTooltip('پنهان کردن رمز'));
    expect(tester.widget<TextField>(box).obscureText, isTrue);
  });
}
