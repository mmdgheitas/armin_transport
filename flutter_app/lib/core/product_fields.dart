/// Conversion between dynamic goods-field values as the API stores them and the raw
/// state of the form controls that edit them. Pure logic, no widgets.
///
/// API value formats: TEXT string · NUMBER integer · DECIMAL string · DATE "YYYY-MM-DD" ·
/// DATETIME ISO 8601 in UTC · BOOLEAN true/false · SELECT option value · MULTI_SELECT [option values].
/// `null` always means "no value".
library;

import 'api/models.dart';
import 'format.dart';

/// The raw state of the control that edits one field. Which members matter depends on the type of the field.
class FieldInput {
  FieldInput({
    this.text = '',
    this.date,
    this.dateIncomplete = false,
    this.time = '',
    this.flag,
    this.choice,
    Set<String>? choices,
  }) : choices = choices ?? <String>{};

  /// TEXT, NUMBER and DECIMAL: what was typed.
  String text;

  /// DATE and DATETIME: the chosen day as "YYYY-MM-DD", or `null` when no day is set.
  String? date;

  /// True while the day is partly entered or does not exist in the calendar.
  bool dateIncomplete;

  /// DATETIME: the time of day as typed, e.g. "14:30".
  String time;

  /// BOOLEAN: yes, no, or not answered.
  bool? flag;

  /// SELECT: the value of the chosen option.
  String? choice;

  /// MULTI_SELECT: the values of the chosen options.
  Set<String> choices;

  /// The state of a control that shows the value stored on the server.
  factory FieldInput.fromApiValue(ProductField field, Object? value) {
    switch (field.dataType) {
      case 'BOOLEAN':
        return FieldInput(flag: value is bool ? value : null);
      case 'SELECT':
        return FieldInput(choice: value is String && value.isNotEmpty ? value : null);
      case 'MULTI_SELECT':
        return FieldInput(choices: value is List ? value.map((item) => item.toString()).toSet() : <String>{});
      case 'DATE':
        return FieldInput(date: value is String && value.isNotEmpty ? value : null);
      case 'DATETIME':
        final parts = instantToLocalParts(value);
        return FieldInput(date: parts.date, time: parts.time);
      default:
        return FieldInput(text: value == null ? '' : value.toString());
    }
  }
}

String _pad2(int value) => value.toString().padLeft(2, '0');

/// ISO instant → the day ("YYYY-MM-DD") and the time ("HH:MM") in the time zone of the device.
({String? date, String time}) instantToLocalParts(Object? value) {
  final instant = parseInstant(value);
  if (instant == null) return (date: null, time: '');
  final local = instant.toLocal();
  return (
    date: '${local.year.toString().padLeft(4, '0')}-${_pad2(local.month)}-${_pad2(local.day)}',
    time: '${_pad2(local.hour)}:${_pad2(local.minute)}',
  );
}

final RegExp _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final RegExp _timeOfDay = RegExp(r'^(\d{1,2}):(\d{2})$');

/// A day and a time of the device's zone → ISO instant in UTC, or `null` when either part is malformed.
String? localPartsToInstant(String? date, String time) {
  final dateMatch = _isoDate.firstMatch(date ?? '');
  final timeMatch = _timeOfDay.firstMatch(toLatinDigits(time).trim());
  if (dateMatch == null || timeMatch == null) return null;
  final year = int.parse(dateMatch.group(1)!);
  final month = int.parse(dateMatch.group(2)!);
  final day = int.parse(dateMatch.group(3)!);
  final hours = int.parse(timeMatch.group(1)!);
  final minutes = int.parse(timeMatch.group(2)!);
  if (hours > 23 || minutes > 59) return null;
  final local = DateTime(year, month, day, hours, minutes);
  if (local.year != year || local.month != month || local.day != day) return null;
  final utc = local.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-${_pad2(utc.month)}-${_pad2(utc.day)}'
      'T${_pad2(utc.hour)}:${_pad2(utc.minute)}:${_pad2(utc.second)}Z';
}

String _normalizeNumberText(String text) => toLatinDigits(text)
    .replaceAll(RegExp(r'[٬,\s]'), '') // thousands separators
    .replaceAll(RegExp('[٫/]'), '.') // Persian decimal separators
    .replaceAll(RegExp('[\u2212\u2013]'), '-');

// 2^53 - 1: larger integers do not survive a trip through JSON in every client.
const int _maxSafeInteger = 9007199254740991;

final RegExp _integerText = RegExp(r'^-?\d+$');
final RegExp _decimalText = RegExp(r'^-?\d+(\.\d+)?$');

/// The value for the API, or the message that explains why the input cannot be read.
class ParsedValue {
  const ParsedValue.value(this.value) : error = null;
  const ParsedValue.error(String this.error) : value = null;

  final Object? value;
  final String? error;
}

/// Converts the state of a form control into the value sent to the API.
/// Only shape problems are reported here; the rules of the field are enforced by the server
/// ([collectFieldValues] additionally checks requiredness and date limits).
ParsedValue inputToApiValue(ProductField field, FieldInput input) {
  switch (field.dataType) {
    case 'TEXT':
      final text = input.text.trim();
      return ParsedValue.value(text.isEmpty ? null : text);
    case 'SELECT':
      return ParsedValue.value(input.choice);
    case 'DATE':
      if (input.dateIncomplete) return const ParsedValue.error('تاریخ را کامل و درست وارد کنید.');
      return ParsedValue.value(input.date);
    case 'NUMBER':
      final text = _normalizeNumberText(input.text.trim());
      if (text.isEmpty) return const ParsedValue.value(null);
      final number = _integerText.hasMatch(text) ? int.tryParse(text) : null;
      if (number == null || number.abs() > _maxSafeInteger) {
        return const ParsedValue.error('یک عدد صحیح معتبر وارد کنید.');
      }
      return ParsedValue.value(number);
    case 'DECIMAL':
      final text = _normalizeNumberText(input.text.trim());
      if (text.isEmpty) return const ParsedValue.value(null);
      if (!_decimalText.hasMatch(text)) return const ParsedValue.error('یک عدد معتبر وارد کنید (مثلاً 12.5).');
      return ParsedValue.value(text);
    case 'BOOLEAN':
      return ParsedValue.value(input.flag);
    case 'MULTI_SELECT':
      // Options keep the order of the definition, whatever the order of the taps.
      final chosen = [for (final option in field.options) if (input.choices.contains(option.value)) option.value];
      return ParsedValue.value(chosen.isEmpty ? null : chosen);
    case 'DATETIME':
      if (input.dateIncomplete) return const ParsedValue.error('تاریخ را کامل و درست وارد کنید.');
      final time = input.time.trim();
      if (input.date == null && time.isEmpty) return const ParsedValue.value(null);
      if (input.date == null) return const ParsedValue.error('تاریخ را کامل وارد کنید.');
      final instant = localPartsToInstant(input.date, time.isEmpty ? '00:00' : time);
      return instant == null ? const ParsedValue.error('ساعت را به شکل ۱۴:۳۰ وارد کنید.') : ParsedValue.value(instant);
    default:
      final text = input.text.trim();
      return ParsedValue.value(text.isEmpty ? null : text);
  }
}

/// A message when a date or date-time breaks the limits of its field, otherwise `null`.
/// The server enforces the same limits but can only name them as Gregorian dates,
/// so the client checks them first and names them in the user's calendar.
String? dateLimitProblem(ProductField field, Object value) {
  final min = field.validationRules['min'];
  final max = field.validationRules['max'];
  if (field.dataType == 'DATE' && value is String) {
    // ISO dates of the same length compare correctly as text.
    if (min is String && value.compareTo(min) < 0) return 'تاریخ نباید قبل از ${formatIsoDate(min)} باشد.';
    if (max is String && value.compareTo(max) > 0) return 'تاریخ نباید بعد از ${formatIsoDate(max)} باشد.';
  }
  if (field.dataType == 'DATETIME') {
    final instant = parseInstant(value);
    final earliest = parseInstant(min);
    final latest = parseInstant(max);
    if (instant == null) return null;
    if (earliest != null && instant.isBefore(earliest)) return 'زمان نباید قبل از ${formatDateTime(earliest)} باشد.';
    if (latest != null && instant.isAfter(latest)) return 'زمان نباید بعد از ${formatDateTime(latest)} باشد.';
  }
  return null;
}

/// Collects API values for all [fields] from [inputs] (keyed by field key).
/// `errors` maps field keys to messages and is empty on success.
({Json values, Map<String, String> errors}) collectFieldValues(List<ProductField> fields, Map<String, FieldInput> inputs) {
  final values = <String, dynamic>{};
  final errors = <String, String>{};
  for (final field in fields) {
    final parsed = inputToApiValue(field, inputs[field.fieldKey] ?? FieldInput());
    final value = parsed.value;
    final String? problem;
    if (parsed.error != null) {
      problem = parsed.error;
    } else if (value == null) {
      problem = field.isRequired ? 'وارد کردن این فیلد الزامی است.' : null;
    } else {
      problem = dateLimitProblem(field, value);
    }
    if (problem != null) {
      errors[field.fieldKey] = problem;
    } else {
      values[field.fieldKey] = value;
    }
  }
  return (values: values, errors: errors);
}

/// Maps API validation errors ("values.weight") to field keys ("weight").
Map<String, String> fieldErrorsFromApi(Map<String, String> apiFields, {String prefix = 'values.'}) => {
  for (final entry in apiFields.entries)
    if (entry.key.startsWith(prefix)) entry.key.substring(prefix.length): entry.value,
};

/// A short Persian description of a field's validation rules for use as an input hint, or `null`.
String? describeRules(ProductField field) {
  final rules = field.validationRules;
  final isDate = field.dataType == 'DATE' || field.dataType == 'DATETIME';
  String show(Object? value) {
    if (field.dataType == 'DATE') return formatIsoDate(value);
    if (field.dataType == 'DATETIME') return formatDateTime(value);
    return formatNumber(value);
  }

  final parts = <String>[
    if (rules['min'] != null) '${isDate ? 'از' : 'حداقل'} ${show(rules['min'])}',
    if (rules['max'] != null) '${isDate ? 'تا' : 'حداکثر'} ${show(rules['max'])}',
    if (rules['min_length'] != null) 'حداقل ${toPersianDigits(rules['min_length'] as Object)} نویسه',
    if (rules['max_length'] != null) 'حداکثر ${toPersianDigits(rules['max_length'] as Object)} نویسه',
    if (rules['max_decimal_places'] != null) 'تا ${toPersianDigits(rules['max_decimal_places'] as Object)} رقم اعشار',
    if (rules['min_items'] != null) 'حداقل ${toPersianDigits(rules['min_items'] as Object)} گزینه',
    if (rules['max_items'] != null) 'حداکثر ${toPersianDigits(rules['max_items'] as Object)} گزینه',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

// ---------------------------------------------------------------------------------------------- definitions

/// One validation rule that can be set for a type of field.
class RuleDefinition {
  const RuleDefinition(this.key, this.label, this.kind);

  final String key;
  final String label;

  /// `integer`, `decimal`, `text`, `date` or `datetime`.
  final String kind;
}

const Map<String, List<RuleDefinition>> ruleDefinitions = {
  'TEXT': [
    RuleDefinition('min_length', 'حداقل طول', 'integer'),
    RuleDefinition('max_length', 'حداکثر طول', 'integer'),
    RuleDefinition('pattern', 'الگو (عبارت باقاعده)', 'text'),
  ],
  'NUMBER': [RuleDefinition('min', 'حداقل مقدار', 'integer'), RuleDefinition('max', 'حداکثر مقدار', 'integer')],
  'DECIMAL': [
    RuleDefinition('min', 'حداقل مقدار', 'decimal'),
    RuleDefinition('max', 'حداکثر مقدار', 'decimal'),
    RuleDefinition('max_decimal_places', 'حداکثر رقم اعشار', 'integer'),
  ],
  'DATE': [RuleDefinition('min', 'از تاریخ', 'date'), RuleDefinition('max', 'تا تاریخ', 'date')],
  'DATETIME': [RuleDefinition('min', 'از زمان', 'datetime'), RuleDefinition('max', 'تا زمان', 'datetime')],
  'BOOLEAN': [],
  'SELECT': [],
  'MULTI_SELECT': [
    RuleDefinition('min_items', 'حداقل تعداد انتخاب', 'integer'),
    RuleDefinition('max_items', 'حداکثر تعداد انتخاب', 'integer'),
  ],
};

/// The state of the control that edits one rule, for the value the definition holds now.
FieldInput ruleValueToInput(String kind, Object? value) {
  switch (kind) {
    case 'date':
      return FieldInput(date: value is String && value.isNotEmpty ? value : null);
    case 'datetime':
      final parts = instantToLocalParts(value);
      return FieldInput(date: parts.date, time: parts.time);
    default:
      return FieldInput(text: value == null ? '' : value.toString());
  }
}

const String _invalidRuleDate = 'تاریخ واردشده کامل یا معتبر نیست.';

/// The outcome of reading one rule: unset, a value, or a message.
({bool isSet, Object? value, String? error}) _parseRule(String kind, FieldInput input) {
  if (kind == 'date') {
    if (input.dateIncomplete) return (isSet: false, value: null, error: _invalidRuleDate);
    return (isSet: input.date != null, value: input.date, error: null);
  }
  if (kind == 'datetime') {
    if (input.dateIncomplete) return (isSet: false, value: null, error: _invalidRuleDate);
    final time = input.time.trim();
    if (input.date == null && time.isEmpty) return (isSet: false, value: null, error: null);
    final instant = localPartsToInstant(input.date, time.isEmpty ? '00:00' : time);
    return instant == null
        ? (isSet: false, value: null, error: _invalidRuleDate)
        : (isSet: true, value: instant, error: null);
  }
  final text = input.text.trim();
  if (text.isEmpty) return (isSet: false, value: null, error: null);
  if (kind == 'integer') {
    final number = _normalizeNumberText(text);
    final parsed = _integerText.hasMatch(number) ? int.tryParse(number) : null;
    return parsed == null || parsed.abs() > _maxSafeInteger
        ? (isSet: false, value: null, error: 'یک عدد صحیح معتبر وارد کنید.')
        : (isSet: true, value: parsed, error: null);
  }
  if (kind == 'decimal') {
    final number = _normalizeNumberText(text);
    return _decimalText.hasMatch(number)
        ? (isSet: true, value: number, error: null)
        : (isSet: false, value: null, error: 'یک عدد معتبر وارد کنید.');
  }
  return (isSet: true, value: text, error: null);
}

/// Builds the `validation_rules` object of a field definition from the state of the rule controls.
/// `rules` is `null` when no rule is set; `errors` is keyed by rule name and empty on success.
({Json? rules, Map<String, String> errors}) buildValidationRules(String dataType, Map<String, FieldInput> inputs) {
  final rules = <String, dynamic>{};
  final errors = <String, String>{};
  for (final definition in ruleDefinitions[dataType] ?? const <RuleDefinition>[]) {
    final parsed = _parseRule(definition.kind, inputs[definition.key] ?? FieldInput());
    if (parsed.error != null) {
      errors[definition.key] = parsed.error!;
    } else if (parsed.isSet) {
      rules[definition.key] = parsed.value;
    }
  }
  return (rules: errors.isEmpty && rules.isNotEmpty ? rules : null, errors: errors);
}

/// Reads the rows of the option editor into the API shape. Blank rows are dropped.
({List<Json>? options, String? error}) buildOptions(List<({String value, String label})> rows) {
  final options = <Json>[];
  final seen = <String>{};
  for (final row in rows) {
    final value = row.value.trim();
    final label = row.label.trim();
    if (value.isEmpty && label.isEmpty) continue;
    if (value.isEmpty || label.isEmpty) return (options: null, error: 'برای هر گزینه هم مقدار و هم برچسب را وارد کنید.');
    if (!seen.add(value)) return (options: null, error: 'مقدار گزینهٔ «$value» تکراری است.');
    options.add(<String, dynamic>{'value': value, 'label': label});
  }
  if (options.isEmpty) return (options: null, error: 'برای فیلد انتخابی دست‌کم یک گزینه لازم است.');
  return (options: options, error: null);
}
