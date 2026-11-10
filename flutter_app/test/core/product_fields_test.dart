import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/product_fields.dart';
import 'package:flutter_test/flutter_test.dart';

ProductField field(
  String type, {
  String? key,
  bool required = false,
  Json rules = const <String, dynamic>{},
  List<String> options = const <String>[],
}) => ProductField(
  id: 'id-${key ?? type}',
  fieldKey: key ?? type.toLowerCase(),
  label: type,
  dataType: type,
  isRequired: required,
  validationRules: rules,
  options: [for (final option in options) ProductFieldOption(value: option, label: 'برچسب $option')],
);

Object? valueOf(ProductField definition, FieldInput input) {
  final parsed = inputToApiValue(definition, input);
  expect(parsed.error, isNull, reason: definition.dataType);
  return parsed.value;
}

String? errorOf(ProductField definition, FieldInput input) => inputToApiValue(definition, input).error;

String two(int value) => value.toString().padLeft(2, '0');

/// The UTC text of a local date and time, computed without the code under test.
String expectedInstant(int year, int month, int day, int hour, int minute) {
  final utc = DateTime(year, month, day, hour, minute).toUtc();
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:00Z';
}

void main() {
  test('converts control state to API values', () {
    expect(valueOf(field('TEXT'), FieldInput(text: '  یخچال  ')), 'یخچال');
    expect(valueOf(field('TEXT'), FieldInput(text: '   ')), isNull);
    expect(valueOf(field('NUMBER'), FieldInput(text: '۲۴')), 24);
    expect(valueOf(field('NUMBER'), FieldInput(text: '1٬250')), 1250);
    expect(valueOf(field('NUMBER'), FieldInput(text: '-7')), -7);
    expect(valueOf(field('NUMBER'), FieldInput()), isNull);
    expect(errorOf(field('NUMBER'), FieldInput(text: '12.5')), contains('عدد صحیح'));
    expect(errorOf(field('NUMBER'), FieldInput(text: 'abc')), isNotNull);
    expect(errorOf(field('NUMBER'), FieldInput(text: '99999999999999999999')), isNotNull);
    expect(errorOf(field('NUMBER'), FieldInput(text: '9007199254740992')), isNotNull);
    expect(valueOf(field('NUMBER'), FieldInput(text: '9007199254740991')), 9007199254740991);
    expect(valueOf(field('DECIMAL'), FieldInput(text: '۱۲۵۰٫۵')), '1250.5');
    expect(valueOf(field('DECIMAL'), FieldInput(text: '1,250.50')), '1250.50');
    // "/" is the usual decimal key on Persian keyboards.
    expect(valueOf(field('DECIMAL'), FieldInput(text: '12/5')), '12.5');
    expect(valueOf(field('DECIMAL'), FieldInput(text: '0.1000000000000000000000001')), '0.1000000000000000000000001');
    expect(valueOf(field('DECIMAL'), FieldInput(text: '\u22123.5')), '-3.5');
    expect(errorOf(field('DECIMAL'), FieldInput(text: '1.2.3')), isNotNull);
    expect(valueOf(field('DATE'), FieldInput(date: '2026-12-01')), '2026-12-01');
    expect(valueOf(field('DATE'), FieldInput()), isNull);
    expect(errorOf(field('DATE'), FieldInput(dateIncomplete: true)), contains('تاریخ'));
    expect(valueOf(field('BOOLEAN'), FieldInput(flag: true)), isTrue);
    expect(valueOf(field('BOOLEAN'), FieldInput(flag: false)), isFalse);
    expect(valueOf(field('BOOLEAN'), FieldInput()), isNull);
    expect(valueOf(field('SELECT'), FieldInput(choice: 'pallet')), 'pallet');
    expect(valueOf(field('SELECT'), FieldInput()), isNull);
    final multi = field('MULTI_SELECT', options: ['a', 'b', 'c']);
    // The order of the definition is kept, whatever the order of the taps.
    expect(valueOf(multi, FieldInput(choices: {'c', 'a'})), ['a', 'c']);
    expect(valueOf(multi, FieldInput()), isNull);
    expect(valueOf(field('SOMETHING_NEW'), FieldInput(text: ' x ')), 'x');
  });

  test('converts date-time controls through the time zone of the device', () {
    final instant = localPartsToInstant('2026-11-10', '14:30');
    expect(instant, expectedInstant(2026, 11, 10, 14, 30));
    expect(instant, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$')));
    expect(instantToLocalParts(instant), (date: '2026-11-10', time: '14:30'));
    expect(instantToLocalParts(null), (date: null, time: ''));
    expect(instantToLocalParts('garbage'), (date: null, time: ''));
    expect(localPartsToInstant('2026-11-10', '۱۴:۳۰'), instant); // Persian digits are accepted
    expect(localPartsToInstant('2026-11-10', '9:05'), expectedInstant(2026, 11, 10, 9, 5));
    expect(localPartsToInstant('2026-11-10', '24:00'), isNull);
    expect(localPartsToInstant('2026-11-10', '12:60'), isNull);
    expect(localPartsToInstant('2026-02-30', '10:00'), isNull);
    expect(localPartsToInstant(null, '10:00'), isNull);
    expect(localPartsToInstant('', '10:00'), isNull);

    final datetime = field('DATETIME');
    expect(valueOf(datetime, FieldInput()), isNull);
    expect(valueOf(datetime, FieldInput(date: '2026-11-10', time: '14:30')), instant);
    expect(valueOf(datetime, FieldInput(date: '2026-11-10')), expectedInstant(2026, 11, 10, 0, 0));
    expect(errorOf(datetime, FieldInput(time: '10:00')), contains('تاریخ'));
    expect(errorOf(datetime, FieldInput(date: '2026-11-10', time: 'noon')), contains('ساعت'));
    expect(errorOf(datetime, FieldInput(dateIncomplete: true, time: '10:00')), contains('تاریخ'));
  });

  test('converts API values to the initial control state', () {
    expect(FieldInput.fromApiValue(field('TEXT'), 'متن').text, 'متن');
    expect(FieldInput.fromApiValue(field('TEXT'), null).text, '');
    expect(FieldInput.fromApiValue(field('NUMBER'), 24).text, '24');
    expect(FieldInput.fromApiValue(field('NUMBER'), 0).text, '0');
    expect(FieldInput.fromApiValue(field('DECIMAL'), '1250.5').text, '1250.5');
    expect(FieldInput.fromApiValue(field('BOOLEAN'), true).flag, isTrue);
    expect(FieldInput.fromApiValue(field('BOOLEAN'), false).flag, isFalse);
    expect(FieldInput.fromApiValue(field('BOOLEAN'), null).flag, isNull);
    expect(FieldInput.fromApiValue(field('SELECT'), 'pallet').choice, 'pallet');
    expect(FieldInput.fromApiValue(field('SELECT'), null).choice, isNull);
    expect(FieldInput.fromApiValue(field('MULTI_SELECT'), ['a']).choices, {'a'});
    expect(FieldInput.fromApiValue(field('MULTI_SELECT'), null).choices, isEmpty);
    expect(FieldInput.fromApiValue(field('DATE'), '2026-12-01').date, '2026-12-01');
    expect(FieldInput.fromApiValue(field('DATETIME'), null).date, isNull);
    expect(FieldInput.fromApiValue(field('DATETIME'), null).time, '');
  });

  test('round-trips every type', () {
    final samples = <(ProductField, Object)>[
      (field('TEXT'), 'نام کالا'),
      (field('NUMBER'), 24),
      (field('DECIMAL'), '1250.5'),
      (field('DATE'), '2026-12-01'),
      (field('BOOLEAN'), false),
      (field('SELECT'), 'pallet'),
      (field('MULTI_SELECT', options: ['insurance', 'loading']), ['insurance', 'loading']),
      (field('DATETIME'), '2026-11-10T10:39:00Z'),
    ];
    for (final (definition, value) in samples) {
      expect(valueOf(definition, FieldInput.fromApiValue(definition, value)), value, reason: definition.dataType);
    }
  });

  test('collects a complete value set and reports missing required fields', () {
    final fields = [
      field('TEXT', key: 'name', required: true),
      field('NUMBER', key: 'count'),
      field('DECIMAL', key: 'weight'),
      field('BOOLEAN', key: 'fragile', required: true),
    ];
    final complete = collectFieldValues(fields, {
      'name': FieldInput(text: 'یخچال'),
      'count': FieldInput(),
      'weight': FieldInput(text: '12.5'),
      'fragile': FieldInput(flag: false),
    });
    // Cleared fields are sent as null.
    expect(complete.values, {'name': 'یخچال', 'count': null, 'weight': '12.5', 'fragile': false});
    expect(complete.errors, isEmpty);

    final invalid = collectFieldValues(fields, {'name': FieldInput(text: ' '), 'count': FieldInput(text: 'x')});
    expect(invalid.errors.keys.toSet(), {'count', 'fragile', 'name'});
    expect(invalid.errors['name'], contains('الزامی'));
    expect(invalid.errors['count'], contains('عدد صحیح'));
    expect(invalid.values.keys, ['weight']);
  });

  test('names a broken date limit in the Jalali calendar before anything is sent', () {
    final delivery = field('DATE', key: 'delivery', rules: {'min': '2026-03-21', 'max': '2026-12-31'});
    Map<String, String> dateErrors(String? date) =>
        collectFieldValues([delivery], {'delivery': FieldInput(date: date)}).errors;
    expect(dateErrors('2026-03-21'), isEmpty);
    expect(dateErrors('2026-12-31'), isEmpty);
    expect(dateErrors('2026-03-20'), {'delivery': 'تاریخ نباید قبل از ۱ فروردین ۱۴۰۵ باشد.'});
    expect(dateErrors('2027-01-01'), {'delivery': 'تاریخ نباید بعد از ۱۰ دی ۱۴۰۵ باشد.'});
    expect(dateErrors(null), isEmpty);

    final pickup = field(
      'DATETIME',
      key: 'pickup',
      rules: {'min': '2026-06-01T08:00:00.000Z', 'max': '2026-06-01T18:00:00.000Z'},
    );
    Map<String, String> timeErrors(String instant) {
      final parts = instantToLocalParts(instant);
      return collectFieldValues([pickup], {'pickup': FieldInput(date: parts.date, time: parts.time)}).errors;
    }

    expect(timeErrors('2026-06-01T08:00:00.000Z'), isEmpty);
    expect(timeErrors('2026-06-01T18:00:00.000Z'), isEmpty);
    expect(timeErrors('2026-06-01T07:59:00.000Z')['pickup'], matches(RegExp(r'^زمان نباید قبل از .+ باشد\.$')));
    expect(timeErrors('2026-06-01T18:01:00.000Z')['pickup'], matches(RegExp(r'^زمان نباید بعد از .+ باشد\.$')));
  });

  test('maps API validation errors back to field keys', () {
    expect(
      fieldErrorsFromApi({'values.weight': 'مقدار باید دست‌کم ۰ باشد.', 'values.name': 'الف ب', 'description': 'نامعتبر'}),
      {'weight': 'مقدار باید دست‌کم ۰ باشد.', 'name': 'الف ب'},
    );
    expect(fieldErrorsFromApi(const {}), isEmpty);
    expect(fieldErrorsFromApi({'product_values.x': 'e'}, prefix: 'product_values.'), {'x': 'e'});
  });

  test('builds validation rules for field definitions', () {
    final text = buildValidationRules('TEXT', {
      'min_length': FieldInput(text: '۲'),
      'max_length': FieldInput(text: '200'),
      'pattern': FieldInput(text: r' ^[A-Z]+$ '),
    });
    expect(text.errors, isEmpty);
    expect(text.rules, {'min_length': 2, 'max_length': 200, 'pattern': r'^[A-Z]+$'});

    expect(buildValidationRules('TEXT', {'min_length': FieldInput(), 'pattern': FieldInput(text: ' ')}).rules, isNull);
    expect(
      buildValidationRules('DECIMAL', {
        'min': FieldInput(text: '0'),
        'max': FieldInput(text: '۱۰۰٫۵'),
        'max_decimal_places': FieldInput(text: '3'),
      }).rules,
      {'min': '0', 'max': '100.5', 'max_decimal_places': 3},
    );
    expect(buildValidationRules('DATE', {'min': FieldInput(date: '2026-01-01'), 'max': FieldInput()}).rules, {
      'min': '2026-01-01',
    });
    // Types without rules ignore stray input.
    expect(buildValidationRules('BOOLEAN', {'min': FieldInput(text: '1')}).rules, isNull);
    expect(buildValidationRules('SELECT', {'anything': FieldInput(text: 'x')}).rules, isNull);
    expect(buildValidationRules('UNKNOWN', {}).rules, isNull);

    final invalid = buildValidationRules('NUMBER', {'min': FieldInput(text: 'abc'), 'max': FieldInput(text: '10')});
    expect(invalid.errors.keys, ['min']);
    expect(invalid.rules, isNull);
    expect(buildValidationRules('MULTI_SELECT', {'min_items': FieldInput(text: '1.5')}).errors, contains('min_items'));
    expect(buildValidationRules('DECIMAL', {'min': FieldInput(text: '1.2.3')}).errors, contains('min'));
  });

  test('builds date and date-time rules from the Jalali controls', () {
    final broken = buildValidationRules('DATE', {
      'min': FieldInput(dateIncomplete: true),
      'max': FieldInput(date: '2026-12-31'),
    });
    expect(broken.errors, {'min': 'تاریخ واردشده کامل یا معتبر نیست.'});
    expect(broken.rules, isNull);

    expect(
      buildValidationRules('DATETIME', {'min': FieldInput(date: '2026-11-10', time: '08:00'), 'max': FieldInput()}).rules,
      {'min': expectedInstant(2026, 11, 10, 8, 0)},
    );
    expect(buildValidationRules('DATETIME', {'min': FieldInput(date: '2026-11-10')}).rules, {
      'min': expectedInstant(2026, 11, 10, 0, 0),
    });
    expect(buildValidationRules('DATETIME', {'min': FieldInput(dateIncomplete: true)}).errors, contains('min'));
    expect(buildValidationRules('DATETIME', {'min': FieldInput(time: '10:00')}).errors, contains('min'));
    expect(buildValidationRules('DATETIME', {'min': FieldInput(date: '2026-11-10', time: 'x')}).errors, contains('min'));
    expect(buildValidationRules('DATETIME', {}).rules, isNull);
  });

  test('every server rule key has an editor, and stored rules round-trip through it', () {
    // Mirrors _RULE_NORMALIZERS in backend/app/modules/product_fields/validation.py.
    const serverRules = {
      'TEXT': ['min_length', 'max_length', 'pattern'],
      'NUMBER': ['min', 'max'],
      'DECIMAL': ['min', 'max', 'max_decimal_places'],
      'DATE': ['min', 'max'],
      'DATETIME': ['min', 'max'],
      'BOOLEAN': <String>[],
      'SELECT': <String>[],
      'MULTI_SELECT': ['min_items', 'max_items'],
    };
    expect(ruleDefinitions.keys.toSet(), serverRules.keys.toSet());
    for (final entry in serverRules.entries) {
      expect([for (final rule in ruleDefinitions[entry.key]!) rule.key], entry.value, reason: entry.key);
    }

    const stored = <String, Json>{
      'TEXT': {'min_length': 2, 'max_length': 200, 'pattern': r'^[A-Z]{2}\d+$'},
      'NUMBER': {'min': -5, 'max': 100},
      'DECIMAL': {'min': '0', 'max': '99999.5', 'max_decimal_places': 3},
      'DATE': {'min': '2026-01-01', 'max': '2026-12-31'},
      'DATETIME': {'min': '2026-01-01T00:00:00Z', 'max': '2026-12-31T20:30:00Z'},
      'MULTI_SELECT': {'min_items': 1, 'max_items': 3},
    };
    for (final entry in stored.entries) {
      final inputs = {
        for (final rule in ruleDefinitions[entry.key]!) rule.key: ruleValueToInput(rule.kind, entry.value[rule.key]),
      };
      final built = buildValidationRules(entry.key, inputs);
      expect(built.errors, isEmpty, reason: entry.key);
      expect(built.rules, entry.value, reason: entry.key);
    }
    expect(ruleValueToInput('integer', null).text, '');
    expect(ruleValueToInput('integer', 0).text, '0');
    expect(ruleValueToInput('datetime', null).date, isNull);
    expect(ruleValueToInput('date', '2026-01-01').date, '2026-01-01');
  });

  test('describes rules as input hints', () {
    expect(describeRules(field('TEXT')), isNull);
    expect(describeRules(field('BOOLEAN')), isNull);
    expect(
      describeRules(field('TEXT', rules: {'min_length': 2, 'max_length': 200, 'pattern': 'x'})),
      'حداقل ۲ نویسه · حداکثر ۲۰۰ نویسه',
    );
    expect(describeRules(field('NUMBER', rules: {'min': 0, 'max': 100000})), 'حداقل ۰ · حداکثر ۱۰۰٬۰۰۰');
    expect(
      describeRules(field('DECIMAL', rules: {'min': '0.5', 'max_decimal_places': 3})),
      'حداقل ۰٫۵ · تا ۳ رقم اعشار',
    );
    expect(describeRules(field('NUMBER', rules: {'min': -25, 'max': 8})), 'حداقل \u2066\u2212۲۵\u2069 · حداکثر ۸');
    expect(
      describeRules(field('DATE', rules: {'min': '2026-03-21', 'max': '2026-12-31'})),
      'از ۱ فروردین ۱۴۰۵ · تا ۱۰ دی ۱۴۰۵',
    );
    expect(
      describeRules(field('DATETIME', rules: {'max': '2026-11-10T10:39:00Z'})),
      matches(RegExp(r'^تا ۱۴۰۵/۰۸/(۱۹|۲۰)، ')),
    );
    expect(
      describeRules(field('MULTI_SELECT', rules: {'min_items': 1, 'max_items': 3})),
      'حداقل ۱ گزینه · حداکثر ۳ گزینه',
    );
  });

  test('reads the option editor', () {
    final built = buildOptions([
      (value: ' pallet ', label: ' پالت '),
      (value: '', label: ''),
      (value: 'box', label: 'کارتن'),
    ]);
    expect(built.error, isNull);
    expect(built.options, [
      {'value': 'pallet', 'label': 'پالت'},
      {'value': 'box', 'label': 'کارتن'},
    ]);
    expect(buildOptions([]).error, contains('دست‌کم یک گزینه'));
    expect(buildOptions([(value: '', label: '  ')]).error, contains('دست‌کم یک گزینه'));
    expect(buildOptions([(value: 'a', label: '')]).error, contains('هم مقدار و هم برچسب'));
    expect(buildOptions([(value: '', label: 'الف')]).error, contains('هم مقدار و هم برچسب'));
    expect(buildOptions([(value: 'a', label: 'الف'), (value: 'a', label: 'ب')]).error, contains('تکراری'));
  });
}
