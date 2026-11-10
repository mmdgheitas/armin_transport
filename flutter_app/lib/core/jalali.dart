/// Conversion between the Gregorian and the Jalali (Persian, Solar Hijri) calendar.
///
/// The algorithm follows the arithmetic rules published by Kazimierz M. Borkowski
/// (the same rules used by the widely deployed "jalaali" libraries) and is valid for
/// Jalali years -61 to 3177. All functions are pure; months are 1-based.
library;

const List<int> _breaks = [
  -61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178, //
];

const List<String> jalaliMonthNames = [
  'فروردین',
  'اردیبهشت',
  'خرداد',
  'تیر',
  'مرداد',
  'شهریور',
  'مهر',
  'آبان',
  'آذر',
  'دی',
  'بهمن',
  'اسفند',
];

const int minJalaliYear = -61;
const int maxJalaliYear = 3177;

/// A calendar date without a time zone. [month] and [day] are 1-based.
class CalendarDate {
  const CalendarDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  @override
  bool operator ==(Object other) =>
      other is CalendarDate && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
}

// Both helpers truncate towards zero, as the published algorithm expects.
int _div(int a, int b) => a ~/ b;
int _mod(int a, int b) => a.remainder(b);

/// Leap-cycle data of a Jalali year: years since the last leap year, and the
/// Gregorian year and day of March on which 1 Farvardin falls.
({int leap, int gy, int march}) _jalaliCalendar(int jy) {
  if (jy < minJalaliYear || jy > maxJalaliYear) {
    throw RangeError('Jalali year out of range: $jy');
  }
  final gy = jy + 621;
  var leapJ = -14;
  var jp = _breaks[0];
  var jump = 0;
  for (var i = 1; i < _breaks.length; i += 1) {
    final jm = _breaks[i];
    jump = jm - jp;
    if (jy < jm) break;
    leapJ += _div(jump, 33) * 8 + _div(_mod(jump, 33), 4);
    jp = jm;
  }
  var n = jy - jp;
  leapJ += _div(n, 33) * 8 + _div(_mod(n, 33) + 3, 4);
  if (_mod(jump, 33) == 4 && jump - n == 4) leapJ += 1;
  final leapG = _div(gy, 4) - _div((_div(gy, 100) + 1) * 3, 4) - 150;
  final march = 20 + leapJ - leapG;
  if (jump - n < 6) n = n - jump + _div(jump + 4, 33) * 33;
  var leap = _mod(_mod(n + 1, 33) - 1, 4);
  if (leap == -1) leap = 4;
  return (leap: leap, gy: gy, march: march);
}

/// Julian day number of a Gregorian date.
int _gregorianToDayNumber(int gy, int gm, int gd) {
  final d = _div((gy + _div(gm - 8, 6) + 100100) * 1461, 4) + _div(153 * _mod(gm + 9, 12) + 2, 5) + gd - 34840408;
  return d - _div(_div(gy + 100100 + _div(gm - 8, 6), 100) * 3, 4) + 752;
}

CalendarDate _dayNumberToGregorian(int jdn) {
  var j = 4 * jdn + 139361631;
  j = j + _div(_div(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
  final i = _div(_mod(j, 1461), 4) * 5 + 308;
  final gd = _div(_mod(i, 153), 5) + 1;
  final gm = _mod(_div(i, 153), 12) + 1;
  final gy = _div(j, 1461) - 100100 + _div(8 - gm, 6);
  return CalendarDate(gy, gm, gd);
}

int _jalaliToDayNumber(int jy, int jm, int jd) {
  final calendar = _jalaliCalendar(jy);
  return _gregorianToDayNumber(calendar.gy, 3, calendar.march) + (jm - 1) * 31 - _div(jm, 7) * (jm - 7) + jd - 1;
}

CalendarDate _dayNumberToJalali(int jdn) {
  final gy = _dayNumberToGregorian(jdn).year;
  var jy = gy - 621;
  final calendar = _jalaliCalendar(jy);
  var k = jdn - _gregorianToDayNumber(gy, 3, calendar.march);
  if (k >= 0) {
    if (k <= 185) return CalendarDate(jy, 1 + _div(k, 31), _mod(k, 31) + 1);
    k -= 186;
  } else {
    jy -= 1;
    k += 179;
    if (calendar.leap == 1) k += 1;
  }
  return CalendarDate(jy, 7 + _div(k, 30), _mod(k, 30) + 1);
}

bool isJalaliLeapYear(int jy) => _jalaliCalendar(jy).leap == 0;

int jalaliMonthLength(int jy, int jm) {
  if (jm <= 6) return 31;
  if (jm <= 11) return 30;
  return isJalaliLeapYear(jy) ? 30 : 29;
}

bool isValidJalaliDate(int jy, int jm, int jd) =>
    jy >= minJalaliYear && jy <= maxJalaliYear && jm >= 1 && jm <= 12 && jd >= 1 && jd <= jalaliMonthLength(jy, jm);

bool isValidGregorianDate(int gy, int gm, int gd) {
  if (gm < 1 || gm > 12 || gd < 1) return false;
  final leap = (gy % 4 == 0 && gy % 100 != 0) || gy % 400 == 0;
  final lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return gd <= lengths[gm - 1];
}

/// Gregorian → Jalali. Throws a [RangeError] for a date that does not exist.
CalendarDate toJalali(int gy, int gm, int gd) {
  if (!isValidGregorianDate(gy, gm, gd)) throw RangeError('Invalid Gregorian date: $gy-$gm-$gd');
  return _dayNumberToJalali(_gregorianToDayNumber(gy, gm, gd));
}

/// Jalali → Gregorian. Throws a [RangeError] for a date that does not exist.
CalendarDate toGregorian(int jy, int jm, int jd) {
  if (!isValidJalaliDate(jy, jm, jd)) throw RangeError('Invalid Jalali date: $jy/$jm/$jd');
  return _dayNumberToGregorian(_jalaliToDayNumber(jy, jm, jd));
}

final RegExp _isoDatePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// "YYYY-MM-DD" (Gregorian, as used by the API) → Jalali date, or `null` when the text is not a valid date.
CalendarDate? isoDateToJalali(String? isoDate) {
  final match = _isoDatePattern.firstMatch((isoDate ?? '').trim());
  if (match == null) return null;
  final gy = int.parse(match.group(1)!);
  final gm = int.parse(match.group(2)!);
  final gd = int.parse(match.group(3)!);
  if (!isValidGregorianDate(gy, gm, gd)) return null;
  // Years before 560 CE lie outside the range of the Jalali rules.
  if (gy < minJalaliYear + 622 || gy > maxJalaliYear + 621) return null;
  return toJalali(gy, gm, gd);
}

/// Jalali date → "YYYY-MM-DD" (Gregorian), or `null` when the Jalali date does not exist.
String? jalaliToIsoDate(int jy, int jm, int jd) {
  if (!isValidJalaliDate(jy, jm, jd)) return null;
  final date = toGregorian(jy, jm, jd);
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}
