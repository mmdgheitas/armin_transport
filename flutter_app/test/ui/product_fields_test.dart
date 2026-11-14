import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/format.dart';
import 'package:armin_transport/core/jalali.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';
import 'support/sample_data.dart';

List<Json> threeFields() => [
  fieldJson(),
  fieldJson(
    id: 'f4',
    key: 'kind',
    label: 'نوع بسته‌بندی',
    type: 'SELECT',
    required: true,
    order: 2,
    options: [
      {'value': 'pallet', 'label': 'پالت'},
      {'value': 'carton', 'label': 'کارتن'},
    ],
  ),
  fieldJson(
    id: 'f5',
    key: 'note',
    label: 'یادداشت',
    type: 'TEXT',
    active: false,
    customerVisible: false,
    order: 3,
    rules: {'max_length': 50},
  ),
];

/// The dropdown of the form field labelled [label].
Finder dropdownOf(String label) => find.descendant(
  of: fieldShell(label),
  matching: find.byWidgetPredicate((widget) => widget is DropdownButtonFormField),
);

/// The text boxes of the date field labelled [label]: the day first, then the year.
Finder dateBoxes(String label) => find.descendant(of: fieldShell(label), matching: find.byType(TextField));

void main() {
  testWidgets('lists the definitions and filters them', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      routes: {
        'GET /product-fields': (request) => ok(pageOf(request.query['q'] == 'هیچ' ? const <Json>[] : threeFields())),
      },
    );
    expect(
      find.text('مشخصات دلخواهی که برای هر محموله ثبت می‌شود. این تعریف‌ها بین همهٔ شرکت‌ها مشترک است.'),
      findsOneWidget,
    );
    // Also the fields that are switched off: this is where they are switched on again.
    expect(app.last('GET /product-fields').query, {'page': '1', 'include_inactive': 'true'});
    expect(find.text('وزن (کیلوگرم)'), findsOneWidget);
    expect(find.text('weight'), findsOneWidget);
    expect(find.text('عدد صحیح'), findsOneWidget);
    expect(find.text('انتخاب تکی (۲ گزینه)'), findsOneWidget);
    // What the rules of a field ask for stands below its label.
    expect(find.text('حداکثر ۵۰ نویسه'), findsOneWidget);
    expect(badge('الزامی'), findsOneWidget);
    expect(find.text('اختیاری'), findsNWidgets(2));
    expect(badge('قابل مشاهده'), findsNWidgets(2));
    expect(badge('پنهان'), findsOneWidget);
    expect(badge('فعال'), findsNWidgets(2));
    expect(badge('غیرفعال'), findsOneWidget);

    await tester.enterText(textBox('جست‌وجو'), ' وزن ');
    await choose(tester, 'وضعیت', 'فقط فعال');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(app.last('GET /product-fields').query, {'page': '1', 'q': 'وزن'});
    expect(find.text('فیلترها (فعال)'), findsOneWidget);

    await tester.enterText(textBox('جست‌وجو'), 'هیچ');
    await tapOn(tester, button('اعمال فیلتر'));
    expect(find.text('فیلدی با این مشخصات پیدا نشد.'), findsOneWidget);

    await tapOn(tester, button('حذف فیلترها'));
    expect(app.last('GET /product-fields').query, {'page': '1', 'include_inactive': 'true'});
    expect(textIn(tester, 'جست‌وجو'), isEmpty);
    expect(find.text('وزن (کیلوگرم)'), findsOneWidget);
  });

  testWidgets('says what fields are good for when none is defined', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      routes: {'GET /product-fields': (request) => ok(pageOf(const <Json>[]))},
    );
    expect(find.text('هنوز فیلدی تعریف نشده است.'), findsOneWidget);
    expect(
      find.text('با تعریف فیلد، مشخصاتی مانند وزن، تعداد یا نوع بسته‌بندی به فرم محموله‌ها افزوده می‌شود.'),
      findsOneWidget,
    );
  });

  testWidgets('defines a field with options and rules', (tester) async {
    final fields = threeFields();
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      routes: {
        'GET /product-fields': (request) => ok(pageOf(fields)),
        'POST /product-fields': (request) {
          final body = request.json as Map;
          if (body['field_key'] == 'kind') {
            return errorResponse(
              409,
              'field_key_taken',
              message: 'فیلد فعال دیگری با همین کلید وجود دارد.',
              extra: {
                'fields': {
                  'field_key': ['فیلد فعال دیگری با این کلید وجود دارد.'],
                },
              },
            );
          }
          fields.add(
            fieldJson(
              id: 'f9',
              key: body['field_key'] as String,
              label: body['label'] as String,
              type: body['data_type'] as String,
              order: body['display_order'] as int,
            ),
          );
          return ok(fields.last, message: 'فیلد با موفقیت تعریف شد.', status: 201);
        },
      },
    );
    final dialog = find.byType(AlertDialog);
    await tapOn(tester, button('فیلد جدید'));
    expect(inDialog(find.text('فیلد جدید')), findsOneWidget);
    // A text field to begin with: rules for texts, and no options.
    expect(fieldShell('حداقل طول'), findsOneWidget);
    expect(fieldShell('الگو (عبارت باقاعده)'), findsOneWidget);
    expect(find.text('گزینه‌ها'), findsNothing);
    expect(textIn(tester, 'ترتیب نمایش'), '0');
    expect(isChecked(tester, 'وارد کردن این فیلد الزامی است'), isFalse);
    expect(isChecked(tester, 'به مشتری نمایش داده شود'), isFalse);
    expect(isChecked(tester, 'فیلد فعال است'), isTrue);

    // Nothing typed: the form says what is missing and asks the server nothing.
    await tapOn(tester, button('تعریف فیلد'));
    expect(find.text('برچسب را وارد کنید.'), findsOneWidget);
    expect(find.text('کلید فیلد را وارد کنید.'), findsOneWidget);

    await tester.enterText(textBox('برچسب'), ' نوع بار ');
    await tester.enterText(textBox('کلید فیلد'), 'Cargo Kind');
    await tester.enterText(textBox('ترتیب نمایش'), 'abc');
    await tapOn(tester, button('تعریف فیلد'));
    expect(find.text('برچسب را وارد کنید.'), findsNothing);
    expect(find.textContaining('کلید باید با حرف کوچک انگلیسی شروع شود'), findsOneWidget);
    expect(find.textContaining('عددی بین ۰ و'), findsOneWidget);

    await tester.enterText(textBox('کلید فیلد'), 'kind');
    await tester.enterText(textBox('ترتیب نمایش'), '۱۲');
    await choose(tester, 'نوع داده', 'انتخاب چندتایی', within: dialog);
    // The rules follow the type, and a type with choices has its options.
    expect(fieldShell('حداقل طول'), findsNothing);
    expect(fieldShell('حداقل تعداد انتخاب'), findsOneWidget);
    expect(find.text('گزینه‌ها'), findsOneWidget);
    expect(boxesWithPlaceholder('value'), findsOneWidget);

    await tapOn(tester, button('تعریف فیلد'));
    expect(find.text('برای فیلد انتخابی دست‌کم یک گزینه لازم است.'), findsOneWidget);

    await tester.enterText(boxesWithPlaceholder('value').at(0), 'bulk');
    await tester.enterText(boxesWithPlaceholder('برچسب').at(0), 'فله');
    await tapOn(tester, button('افزودن گزینه'));
    await tester.enterText(boxesWithPlaceholder('value').at(1), 'bulk');
    await tester.enterText(boxesWithPlaceholder('برچسب').at(1), 'کیسه');
    await tapOn(tester, button('تعریف فیلد'));
    expect(find.text('مقدار گزینهٔ «bulk» تکراری است.'), findsOneWidget);

    await tester.enterText(boxesWithPlaceholder('value').at(1), ' bag ');
    await tapOn(tester, button('افزودن گزینه'));
    await tester.enterText(boxesWithPlaceholder('برچسب').at(2), 'ناتمام');
    await tapOn(tester, button('تعریف فیلد'));
    expect(find.text('برای هر گزینه هم مقدار و هم برچسب را وارد کنید.'), findsOneWidget);
    await tapOn(tester, find.byTooltip('حذف گزینه').at(2));
    expect(boxesWithPlaceholder('value'), findsNWidgets(2));
    expect(find.text('ناتمام'), findsNothing);

    await tester.enterText(textBox('حداقل تعداد انتخاب'), '۱');
    await tester.enterText(textBox('حداکثر تعداد انتخاب'), 'x');
    await tapOn(tester, button('تعریف فیلد'));
    expect(find.text('یک عدد صحیح معتبر وارد کنید.'), findsOneWidget);
    expect(find.text('قواعد مشخص‌شده را اصلاح کنید.'), findsOneWidget);
    expect(find.text('برای هر گزینه هم مقدار و هم برچسب را وارد کنید.'), findsNothing);
    expect(app.count('POST /product-fields'), 0);

    // Everything is in order now, but the key is taken.
    await tester.enterText(textBox('حداکثر تعداد انتخاب'), '2');
    await tapOn(tester, checkBox('وارد کردن این فیلد الزامی است'));
    await tapOn(tester, button('تعریف فیلد'));
    expect(inDialog(find.text('فیلد فعال دیگری با این کلید وجود دارد.')), findsOneWidget);
    expect(inDialog(find.text('فیلد فعال دیگری با همین کلید وجود دارد.')), findsOneWidget);
    expect(find.text('قواعد مشخص‌شده را اصلاح کنید.'), findsNothing);

    await tester.enterText(textBox('کلید فیلد'), ' cargo_kind ');
    await tapOn(tester, button('تعریف فیلد'));
    expect(dialog, findsNothing);
    expect(app.last('POST /product-fields').json, {
      'label': 'نوع بار',
      'is_required': true,
      'is_customer_visible': false,
      'is_active': true,
      'display_order': 12,
      'validation_rules': {'min_items': 1, 'max_items': 2},
      'options': [
        {'value': 'bulk', 'label': 'فله'},
        {'value': 'bag', 'label': 'کیسه'},
      ],
      'field_key': 'cargo_kind',
      'data_type': 'MULTI_SELECT',
    });
    expect(find.text('فیلد با موفقیت تعریف شد.'), findsOneWidget);
    expect(find.text('نوع بار'), findsOneWidget);
    expect(find.text('cargo_kind'), findsOneWidget);
    expect(app.count('GET /product-fields'), 2);
  });

  testWidgets('changing the type starts its rules over', (tester) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      routes: {
        'GET /product-fields': (request) => ok(pageOf(threeFields())),
        'POST /product-fields': (request) => ok(
          fieldJson(id: 'f9', key: 'fragile', label: 'شکستنی', type: 'BOOLEAN'),
          message: 'فیلد با موفقیت تعریف شد.',
        ),
      },
    );
    final dialog = find.byType(AlertDialog);
    await tapOn(tester, button('فیلد جدید'));
    await tester.enterText(textBox('برچسب'), 'شکستنی');
    await tester.enterText(textBox('کلید فیلد'), 'fragile');
    await tester.enterText(textBox('حداقل طول'), '3');

    await choose(tester, 'نوع داده', 'عدد صحیح', within: dialog);
    expect(fieldShell('حداقل طول'), findsNothing);
    expect(textIn(tester, 'حداقل مقدار'), isEmpty);
    await tester.enterText(textBox('حداقل مقدار'), '7');

    // Back at the first type: what was typed for it is gone, and nothing of the other type is left.
    await choose(tester, 'نوع داده', 'متن', within: dialog);
    expect(fieldShell('حداقل مقدار'), findsNothing);
    expect(textIn(tester, 'حداقل طول'), isEmpty);

    // Yes or no: nothing to restrict, nothing to choose from.
    await choose(tester, 'نوع داده', 'بله / خیر', within: dialog);
    expect(find.text('قواعد اعتبارسنجی'), findsNothing);
    expect(find.text('گزینه‌ها'), findsNothing);
    await tapOn(tester, button('تعریف فیلد'));
    expect(app.last('POST /product-fields').json, {
      'label': 'شکستنی',
      'is_required': false,
      'is_customer_visible': false,
      'is_active': true,
      'display_order': 0,
      'validation_rules': null,
      'options': null,
      'field_key': 'fragile',
      'data_type': 'BOOLEAN',
    });
  });

  testWidgets('edits a definition; its key and type stay as they are', (tester) async {
    var field = fieldJson(
      id: 'f6',
      key: 'volume',
      label: 'حجم',
      type: 'DECIMAL',
      order: 4,
      rules: {'min': '0.5', 'max_decimal_places': 2},
    );
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      routes: {
        'GET /product-fields': (request) => ok(pageOf([field])),
        'PATCH /product-fields/f6': (request) {
          final body = request.json as Map;
          final rules = body['validation_rules'] as Map;
          if ((rules['max_decimal_places'] as int) > 10) {
            return errorResponse(
              422,
              'validation_error',
              message: 'اطلاعات واردشده معتبر نیست.',
              extra: {
                'fields': {
                  'validation_rules.max_decimal_places': ['تعداد رقم اعشار باید بین ۰ و ۱۰ باشد.'],
                },
              },
            );
          }
          field = {...field, 'label': body['label'], 'validation_rules': rules};
          return ok(field, message: 'فیلد به‌روزرسانی شد.');
        },
      },
    );
    expect(find.text('حداقل ${formatNumber('0.5')} · تا ۲ رقم اعشار'), findsOneWidget);
    await tapOn(tester, find.byTooltip('ویرایش فیلد حجم'));
    expect(inDialog(find.text('ویرایش فیلد «حجم»')), findsOneWidget);
    expect(find.textContaining('نسخهٔ فیلد را افزایش می‌دهد'), findsOneWidget);
    expect(textIn(tester, 'برچسب'), 'حجم');
    expect(textIn(tester, 'ترتیب نمایش'), '4');
    expect(textIn(tester, 'حداقل مقدار'), '0.5');
    expect(textIn(tester, 'حداکثر مقدار'), isEmpty);
    expect(textIn(tester, 'حداکثر رقم اعشار'), '2');
    expect(isChecked(tester, 'به مشتری نمایش داده شود'), isTrue);

    // Values recorded under the key, in the type: neither can change any more.
    expect(textIn(tester, 'کلید فیلد'), 'volume');
    expect(tester.widget<TextField>(textBox('کلید فیلد')).enabled, isFalse);
    expect(tester.widget<DropdownButtonFormField<String>>(dropdownOf('نوع داده')).onChanged, isNull);
    expect(find.text('کلید فیلد قابل تغییر نیست.'), findsOneWidget);

    await tester.enterText(textBox('برچسب'), 'حجم (متر مکعب)');
    await tester.enterText(textBox('حداقل مقدار'), '');
    await tester.enterText(textBox('حداکثر مقدار'), '۱۰۰٫۵');
    await tester.enterText(textBox('حداکثر رقم اعشار'), '12');
    await tapOn(tester, checkBox('به مشتری نمایش داده شود'));
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    // What the server says about a single rule is shown with the rules; no summary besides it.
    expect(inDialog(find.text('تعداد رقم اعشار باید بین ۰ و ۱۰ باشد.')), findsOneWidget);
    expect(find.text('اطلاعات واردشده معتبر نیست.'), findsNothing);

    await tester.enterText(textBox('حداکثر رقم اعشار'), '3');
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.last('PATCH /product-fields/f6').json, {
      'label': 'حجم (متر مکعب)',
      'is_required': false,
      'is_customer_visible': false,
      'is_active': true,
      'display_order': 4,
      'validation_rules': {'max': '100.5', 'max_decimal_places': 3},
      'options': null,
    });
    expect(find.text('فیلد به‌روزرسانی شد.'), findsOneWidget);
    expect(find.text('حجم (متر مکعب)'), findsOneWidget);
    expect(app.count('GET /product-fields'), 2);
  });

  testWidgets('edits the options of a field; what the server says about one of them is shown with them', (
    tester,
  ) async {
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      routes: {
        'GET /product-fields': (request) => ok(pageOf(threeFields())),
        'PATCH /product-fields/f4': (request) {
          final options = (request.json as Map)['options'] as List;
          if (options.length < 2) {
            return errorResponse(
              422,
              'validation_error',
              message: 'اطلاعات واردشده معتبر نیست.',
              extra: {
                'fields': {
                  'options.0.value': ['حذف گزینه‌ای که مقدار ثبت‌شده دارد ممکن نیست.'],
                },
              },
            );
          }
          return ok(threeFields()[1], message: 'فیلد به‌روزرسانی شد.');
        },
      },
    );
    await tapOn(tester, find.byTooltip('ویرایش فیلد نوع بسته‌بندی'));
    final values = boxesWithPlaceholder('value');
    final labels = boxesWithPlaceholder('برچسب');
    expect(values, findsNWidgets(2));
    expect(tester.widget<TextField>(values.at(0)).controller?.text, 'pallet');
    expect(tester.widget<TextField>(labels.at(1)).controller?.text, 'کارتن');
    // A single choice has options, but no rules.
    expect(find.text('قواعد اعتبارسنجی'), findsNothing);

    await tapOn(tester, find.byTooltip('حذف گزینه').at(0));
    expect(values, findsOneWidget);
    expect(tester.widget<TextField>(values.at(0)).controller?.text, 'carton');
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(inDialog(find.text('حذف گزینه‌ای که مقدار ثبت‌شده دارد ممکن نیست.')), findsOneWidget);
    expect(find.text('اطلاعات واردشده معتبر نیست.'), findsNothing);

    await tapOn(tester, button('افزودن گزینه'));
    await tester.enterText(values.at(1), 'box');
    await tester.enterText(labels.at(1), 'جعبه');
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.last('PATCH /product-fields/f4').json, {
      'label': 'نوع بسته‌بندی',
      'is_required': true,
      'is_customer_visible': true,
      'is_active': true,
      'display_order': 2,
      'validation_rules': null,
      'options': [
        {'value': 'carton', 'label': 'کارتن'},
        {'value': 'box', 'label': 'جعبه'},
      ],
    });
  });

  testWidgets('the limits of a date field are days of the Persian calendar', (tester) async {
    final field = fieldJson(
      id: 'f7',
      key: 'loaded_on',
      label: 'تاریخ بارگیری',
      type: 'DATE',
      rules: {'min': '2026-03-21'},
    );
    final app = await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      routes: {
        'GET /product-fields': (request) => ok(pageOf([field])),
        'PATCH /product-fields/f7': (request) => ok(field, message: 'فیلد به‌روزرسانی شد.'),
      },
    );
    await tapOn(tester, find.byTooltip('ویرایش فیلد تاریخ بارگیری'));
    final from = dateBoxes('از تاریخ');
    final to = dateBoxes('تا تاریخ');
    // The first day of the year 1405.
    expect(tester.widget<TextField>(from.at(0)).controller?.text, '۱');
    expect(tester.widget<TextField>(from.at(1)).controller?.text, '۱۴۰۵');
    expect(tester.widget<TextField>(to.at(0)).controller?.text, isEmpty);

    // A day without month and year is not a date.
    await tester.enterText(to.at(0), '31');
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(find.text('تاریخ واردشده کامل یا معتبر نیست.'), findsOneWidget);
    expect(find.text('قواعد مشخص‌شده را اصلاح کنید.'), findsOneWidget);
    expect(app.count('PATCH /product-fields/f7'), 0);

    await choose(tester, 'تا تاریخ', 'شهریور');
    await tester.enterText(to.at(1), '۱۴۰۵');
    await tapOn(tester, button('ذخیرهٔ تغییرات'));
    expect(find.byType(AlertDialog), findsNothing);
    final lastDay = jalaliToIsoDate(1405, 6, 31);
    expect(lastDay, '2026-09-22');
    expect((app.last('PATCH /product-fields/f7').json as Map)['validation_rules'], {
      'min': '2026-03-21',
      'max': lastDay,
    });
  });

  testWidgets('on a phone the definitions are cards and the form fits the screen', (tester) async {
    await pumpApp(
      tester,
      auth: adminAuthPayload(),
      location: '/product-fields',
      size: phoneSize,
      routes: {'GET /product-fields': (request) => ok(pageOf(threeFields()))},
    );
    final dialog = find.byType(AlertDialog);
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('نوع بسته‌بندی'), findsOneWidget);
    expect(find.text('حداکثر ۵۰ نویسه'), findsOneWidget);

    await tapOn(tester, button('فیلد جدید'));
    // A moment in time: the day and, on a line of its own, the time of day.
    await choose(tester, 'نوع داده', 'تاریخ و زمان', within: dialog);
    expect(fieldShell('از زمان'), findsOneWidget);
    expect(find.byTooltip('انتخاب ساعت'), findsNWidgets(2));
    await choose(tester, 'نوع داده', 'انتخاب تکی', within: dialog);
    expect(boxesWithPlaceholder('value'), findsOneWidget);
    await tapOn(tester, button('افزودن گزینه'));
    expect(boxesWithPlaceholder('value'), findsNWidgets(2));
    await tapOn(tester, button('تعریف فیلد'));
    expect(find.text('برچسب را وارد کنید.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The definition of an existing field opens from its card.
    await tapOn(tester, button('انصراف'));
    await tapOn(tester, find.byTooltip('ویرایش فیلد یادداشت'));
    expect(textIn(tester, 'حداکثر طول'), '50');
    expect(isChecked(tester, 'فیلد فعال است'), isFalse);
    expect(tester.takeException(), isNull);
  });
}
