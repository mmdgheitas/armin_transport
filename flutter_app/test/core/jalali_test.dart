import 'package:armin_transport/core/jalali.dart';
import 'package:flutter_test/flutter_test.dart';

/// The day of March (minus 19) on which the Jalali years 1278 to 1480 begin, one digit per year.
/// Taken from the Persian calendar of ICU, so it is independent of the arithmetic under test.
const String _nowruzOffsets =
    '22233223322332233223322332233222322232223222322232223222322232222222222222222222222222222222222221222122'
    '212221222122212221222122211221122112211221122112211221122111211121112111211121112111211121111111122';
const int _firstYear = 1278;

DateTime _nowruz(int jalaliYear) =>
    DateTime.utc(jalaliYear + 621, 3, 19 + int.parse(_nowruzOffsets[jalaliYear - _firstYear]));

void main() {
  test('converts well-known dates in both directions', () {
    const pairs = [
      ([2024, 3, 20], [1403, 1, 1]), // Nowruz 1403
      ([2025, 3, 20], [1403, 12, 30]), // last day of a leap year
      ([2025, 3, 21], [1404, 1, 1]),
      ([2026, 3, 21], [1405, 1, 1]),
      ([2026, 11, 10], [1405, 8, 19]),
      ([2021, 3, 20], [1399, 12, 30]),
      ([1979, 2, 11], [1357, 11, 22]),
      ([2000, 1, 1], [1378, 10, 11]),
      ([2026, 12, 1], [1405, 9, 10]),
    ];
    for (final (gregorian, jalali) in pairs) {
      expect(toJalali(gregorian[0], gregorian[1], gregorian[2]), CalendarDate(jalali[0], jalali[1], jalali[2]));
      expect(toGregorian(jalali[0], jalali[1], jalali[2]), CalendarDate(gregorian[0], gregorian[1], gregorian[2]));
    }
  });

  test('agrees with the ICU Persian calendar for every day of the Jalali years 1278 to 1479', () {
    expect(_nowruzOffsets.length, 203);
    var checked = 0;
    for (var year = _firstYear; year < _firstYear + _nowruzOffsets.length - 1; year += 1) {
      final start = _nowruz(year);
      final length = _nowruz(year + 1).difference(start).inDays;
      expect(length == 365 || length == 366, isTrue, reason: 'length of $year');
      expect(isJalaliLeapYear(year), length == 366, reason: 'leap year $year');

      var month = 1;
      var day = 1;
      for (var offset = 0; offset < length; offset += 1) {
        final date = start.add(Duration(days: offset));
        final expected = CalendarDate(year, month, day);
        final actual = toJalali(date.year, date.month, date.day);
        if (actual != expected) fail('${date.toIso8601String()}: expected $expected, got $actual');
        final back = toGregorian(year, month, day);
        if (back != CalendarDate(date.year, date.month, date.day)) fail('round trip failed for $expected: $back');
        checked += 1;

        // The first six months have 31 days, the next five 30, and the last one whatever remains.
        final monthLength = month <= 6 ? 31 : (month <= 11 ? 30 : length - 336);
        expect(jalaliMonthLength(year, month), monthLength);
        if (day == monthLength) {
          month += 1;
          day = 1;
        } else {
          day += 1;
        }
      }
      expect((month, day), (13, 1), reason: 'end of $year');
    }
    expect(checked, 73779);
  });

  test('knows leap years and month lengths', () {
    for (final year in [1370, 1375, 1379, 1383, 1387, 1391, 1395, 1399, 1403, 1408]) {
      expect(isJalaliLeapYear(year), isTrue, reason: '$year');
      expect(jalaliMonthLength(year, 12), 30);
    }
    for (final year in [1400, 1401, 1402, 1404, 1405, 1406, 1407]) {
      expect(isJalaliLeapYear(year), isFalse, reason: '$year');
      expect(jalaliMonthLength(year, 12), 29);
    }
    expect(jalaliMonthLength(1405, 1), 31);
    expect(jalaliMonthLength(1405, 6), 31);
    expect(jalaliMonthLength(1405, 7), 30);
    expect(jalaliMonthLength(1405, 11), 30);
  });

  test('validates dates', () {
    expect(isValidJalaliDate(1403, 12, 30), isTrue);
    expect(isValidJalaliDate(1404, 12, 30), isFalse);
    expect(isValidJalaliDate(1404, 7, 31), isFalse);
    expect(isValidJalaliDate(1404, 13, 1), isFalse);
    expect(isValidJalaliDate(1404, 0, 1), isFalse);
    expect(isValidJalaliDate(1404, 1, 0), isFalse);
    expect(isValidJalaliDate(99999, 1, 1), isFalse);
    expect(isValidGregorianDate(2024, 2, 29), isTrue);
    expect(isValidGregorianDate(2023, 2, 29), isFalse);
    expect(isValidGregorianDate(1900, 2, 29), isFalse);
    expect(isValidGregorianDate(2000, 2, 29), isTrue);
    expect(() => toGregorian(1404, 12, 30), throwsRangeError);
    expect(() => toJalali(2023, 2, 30), throwsRangeError);
  });

  test('converts ISO date text used by the API', () {
    expect(isoDateToJalali('2026-12-01'), const CalendarDate(1405, 9, 10));
    expect(jalaliToIsoDate(1405, 9, 10), '2026-12-01');
    expect(jalaliToIsoDate(1403, 1, 1), '2024-03-20');
    expect(jalaliToIsoDate(1404, 12, 30), isNull);
    for (final invalid in ['', null, '2026-13-01', '2026-02-30', '1405/09/10', '2026-1-1', 'abc', '0001-01-01']) {
      expect(isoDateToJalali(invalid), isNull, reason: '$invalid');
    }
  });

  test('describes a date as text', () {
    expect(const CalendarDate(1405, 8, 19).toString(), '1405-08-19');
    expect(const CalendarDate(1405, 8, 19).hashCode, const CalendarDate(1405, 8, 19).hashCode);
    expect(jalaliMonthNames, hasLength(12));
    expect(jalaliMonthNames[7], 'آبان');
  });
}
