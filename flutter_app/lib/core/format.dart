/// Presentation helpers: Persian digits, Jalali dates, file sizes and typed product values.
library;

import 'jalali.dart';

const String _persianDigits = '۰۱۲۳۴۵۶۷۸۹';
const String _thousandsSeparator = '٬';
const String _decimalSeparator = '٫';
const String emptyPlaceholder = '—';

// In right-to-left text a minus sign would be drawn to the right of the digits; the isolate keeps it on the left.
const String _leftToRightIsolate = '\u2066';
const String _popDirectionalIsolate = '\u2069';
const String _minusSign = '\u2212';

final RegExp _asciiDigit = RegExp(r'\d');
final RegExp _persianDigit = RegExp('[۰-۹]');
final RegExp _arabicDigit = RegExp('[٠-٩]');
final RegExp _decimalText = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$');
final RegExp _groupBoundary = RegExp(r'\B(?=(\d{3})+(?!\d))');

String toPersianDigits(Object value) =>
    value.toString().replaceAllMapped(_asciiDigit, (match) => _persianDigits[int.parse(match.group(0)!)]);

/// Persian (۰-۹) and Arabic-Indic (٠-٩) digits → ASCII digits; other characters are kept.
String toLatinDigits(String value) => value
    .replaceAllMapped(_persianDigit, (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0x06f0 + 0x30))
    .replaceAllMapped(_arabicDigit, (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0x0660 + 0x30));

/// Wraps text that must keep its left-to-right order (codes, file names, user names) inside Persian text.
String ltrIsolate(String text) => '$_leftToRightIsolate$text$_popDirectionalIsolate';

/// Formats a decimal number given as text ("-1250.50") without going through floating
/// point, so values keep exactly the digits the server returned.
String formatDecimalText(String text) {
  final match = _decimalText.firstMatch(text.trim());
  if (match == null) return toPersianDigits(text);
  final negative = match.group(1) == '-';
  final grouped = match.group(2)!.replaceAll(_groupBoundary, _thousandsSeparator);
  final fraction = match.group(3);
  final digits = toPersianDigits(fraction == null ? grouped : '$grouped$_decimalSeparator$fraction');
  return negative ? '$_leftToRightIsolate$_minusSign$digits$_popDirectionalIsolate' : digits;
}

/// Formats an integer, a decimal given as text, or `null` (shown as a dash).
String formatNumber(Object? value) {
  if (value == null || value == '') return emptyPlaceholder;
  if (value is double) {
    if (!value.isFinite) return emptyPlaceholder;
    return formatDecimalText(value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString());
  }
  return formatDecimalText(value.toString());
}

const List<String> _sizeUnits = ['بایت', 'کیلوبایت', 'مگابایت', 'گیگابایت'];

String formatFileSize(int? bytes) {
  if (bytes == null || bytes < 0) return emptyPlaceholder;
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _sizeUnits.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final String rounded;
  if (unit == 0 || value >= 100) {
    rounded = value.round().toString();
  } else {
    final tenths = (value * 10).round();
    rounded = tenths % 10 == 0 ? (tenths ~/ 10).toString() : '${tenths ~/ 10}.${tenths % 10}';
  }
  return '${formatDecimalText(rounded)} ${_sizeUnits[unit]}';
}

String _pad2(int value) => value.toString().padLeft(2, '0');

String _jalaliText(CalendarDate date, {required bool long}) => long
    ? toPersianDigits('${date.day} ${jalaliMonthNames[date.month - 1]} ${date.year}')
    : toPersianDigits('${date.year}/${_pad2(date.month)}/${_pad2(date.day)}');

/// Parses an instant as the API sends it (ISO 8601, UTC). Returns `null` for anything else.
DateTime? parseInstant(Object? value) {
  if (value is DateTime) return value;
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}

DateTime _inZone(DateTime instant, bool utc) => utc ? instant.toUtc() : instant.toLocal();

/// Formats an instant as a Jalali date in the viewer's time zone: ۱۴۰۵/۰۸/۱۹, or ۱۹ آبان ۱۴۰۵ when [long].
String formatDate(Object? value, {bool long = false, bool utc = false}) {
  final instant = parseInstant(value);
  if (instant == null) return emptyPlaceholder;
  final moment = _inZone(instant, utc);
  if (moment.year < 561 || moment.year > 3798) return emptyPlaceholder;
  return _jalaliText(toJalali(moment.year, moment.month, moment.day), long: long);
}

String formatTime(Object? value, {bool utc = false}) {
  final instant = parseInstant(value);
  if (instant == null) return emptyPlaceholder;
  final moment = _inZone(instant, utc);
  return toPersianDigits('${_pad2(moment.hour)}:${_pad2(moment.minute)}');
}

String formatDateTime(Object? value, {bool long = false, bool utc = false}) {
  final instant = parseInstant(value);
  if (instant == null) return emptyPlaceholder;
  final separator = long ? '، ساعت ' : '، ';
  return '${formatDate(instant, long: long, utc: utc)}$separator${formatTime(instant, utc: utc)}';
}

/// Formats a calendar date ("YYYY-MM-DD") that has no time zone, e.g. a DATE product field.
String formatIsoDate(Object? isoDate, {bool long = true}) {
  final jalali = isoDate is String ? isoDateToJalali(isoDate) : null;
  return jalali == null ? emptyPlaceholder : _jalaliText(jalali, long: long);
}

/// "N minutes" style text for short durations given in seconds.
String formatDuration(num? seconds) {
  final total = seconds == null || !seconds.isFinite ? 0 : (seconds < 0 ? 0 : seconds.round());
  if (total < 60) return '${toPersianDigits(total)} ثانیه';
  final minutes = (total / 60).round();
  if (minutes < 60) return '${toPersianDigits(minutes)} دقیقه';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${toPersianDigits(hours)} ساعت' : '${toPersianDigits(hours)} ساعت و ${toPersianDigits(rest)} دقیقه';
}

const Map<String, String> fieldTypeLabels = {
  'TEXT': 'متن',
  'NUMBER': 'عدد صحیح',
  'DECIMAL': 'عدد اعشاری',
  'DATE': 'تاریخ',
  'DATETIME': 'تاریخ و زمان',
  'BOOLEAN': 'بله / خیر',
  'SELECT': 'انتخاب تکی',
  'MULTI_SELECT': 'انتخاب چندتایی',
};

/// Human-readable text of a product-field value.
/// [value] is the display value returned by the API (option labels for select fields).
String formatFieldValue(String dataType, Object? value) {
  if (value == null || value == '' || (value is List && value.isEmpty)) return emptyPlaceholder;
  switch (dataType) {
    case 'NUMBER':
    case 'DECIMAL':
      return formatNumber(value);
    case 'DATE':
      return formatIsoDate(value);
    case 'DATETIME':
      return formatDateTime(value, long: true);
    case 'BOOLEAN':
      return value == true ? 'بله' : 'خیر';
    case 'MULTI_SELECT':
      return value is List ? value.map((item) => item.toString()).join('، ') : value.toString();
    default:
      return value.toString();
  }
}
