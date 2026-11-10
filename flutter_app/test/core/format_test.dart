import 'package:armin_transport/core/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('converts digits between scripts', () {
    expect(toPersianDigits('ABC-0123456789'), 'ABC-۰۱۲۳۴۵۶۷۸۹');
    expect(toPersianDigits(42), '۴۲');
    expect(toLatinDigits('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
    expect(toLatinDigits('٠١٢٣٤٥٦٧٨٩'), '0123456789');
    expect(toLatinDigits('کد ۱۲-AB'), 'کد 12-AB');
  });

  test('formats numbers without floating point artefacts', () {
    expect(formatNumber(0), '۰');
    expect(formatNumber(1234567), '۱٬۲۳۴٬۵۶۷');
    // A negative number is isolated as left-to-right text so that its sign stays on the left of the digits.
    expect(formatNumber(-1500), '\u2066\u2212۱٬۵۰۰\u2069');
    expect(formatNumber('-0.5'), '\u2066\u2212۰٫۵\u2069');
    expect(formatNumber('1250.5'), '۱٬۲۵۰٫۵');
    expect(formatNumber('0.1000'), '۰٫۱۰۰۰');
    expect(formatNumber(12.0), '۱۲');
    expect(formatNumber(2.5), '۲٫۵');
    expect(
      formatDecimalText('123456789012345678901234567890.123456789'),
      '۱۲۳٬۴۵۶٬۷۸۹٬۰۱۲٬۳۴۵٬۶۷۸٬۹۰۱٬۲۳۴٬۵۶۷٬۸۹۰٫۱۲۳۴۵۶۷۸۹',
    );
    expect(formatNumber(null), emptyPlaceholder);
    expect(formatNumber(''), emptyPlaceholder);
    expect(formatNumber(double.nan), emptyPlaceholder);
    expect(formatNumber(double.infinity), emptyPlaceholder);
    expect(formatNumber('not a number'), 'not a number');
  });

  test('keeps left-to-right text in order inside Persian text', () {
    expect(ltrIsolate('AB-12'), '\u2066AB-12\u2069');
  });

  test('formats file sizes', () {
    expect(formatFileSize(0), '۰ بایت');
    expect(formatFileSize(1023), '۱٬۰۲۳ بایت');
    expect(formatFileSize(1024), '۱ کیلوبایت');
    expect(formatFileSize(1536), '۱٫۵ کیلوبایت');
    expect(formatFileSize(10 * 1024 * 1024), '۱۰ مگابایت');
    expect(formatFileSize(3489660928), '۳٫۳ گیگابایت'); // 3.25 GB
    expect(formatFileSize(150 * 1024 * 1024), '۱۵۰ مگابایت');
    expect(formatFileSize(5 * 1024 * 1024 * 1024 * 1024), '۵٬۱۲۰ گیگابایت');
    expect(formatFileSize(-1), emptyPlaceholder);
    expect(formatFileSize(null), emptyPlaceholder);
  });

  test('formats instants as Jalali dates', () {
    const instant = '2026-11-10T10:39:05.123Z';
    expect(formatDate(instant, utc: true), '۱۴۰۵/۰۸/۱۹');
    expect(formatDate(instant, utc: true, long: true), '۱۹ آبان ۱۴۰۵');
    expect(formatTime(instant, utc: true), '۱۰:۳۹');
    expect(formatDateTime(instant, utc: true), '۱۴۰۵/۰۸/۱۹، ۱۰:۳۹');
    expect(formatDateTime(instant, utc: true, long: true), '۱۹ آبان ۱۴۰۵، ساعت ۱۰:۳۹');
    expect(formatDate(DateTime.utc(2024, 3, 20), utc: true), '۱۴۰۳/۰۱/۰۱');
    // An offset in the text is honoured: 23:30 at +03:30 is 20:00 UTC.
    expect(formatDateTime('2026-11-10T23:30:00+03:30', utc: true), '۱۴۰۵/۰۸/۱۹، ۲۰:۰۰');
    for (final invalid in [null, '', 'garbage', 42]) {
      expect(formatDate(invalid), emptyPlaceholder);
      expect(formatDateTime(invalid), emptyPlaceholder);
      expect(formatTime(invalid), emptyPlaceholder);
    }
    // Years outside the range of the Jalali rules are not shown as nonsense.
    expect(formatDate('0001-01-01T00:00:00Z', utc: true), emptyPlaceholder);
  });

  test('uses the time zone of the device by default', () {
    final local = DateTime(2026, 11, 10, 23, 59); // 10 Nov 2026, 23:59 local time
    expect(formatDateTime(local), '۱۴۰۵/۰۸/۱۹، ۲۳:۵۹');
    expect(formatDateTime(local.toUtc()), '۱۴۰۵/۰۸/۱۹، ۲۳:۵۹');
  });

  test('formats calendar dates without time zone shifts', () {
    expect(formatIsoDate('2026-12-01'), '۱۰ آذر ۱۴۰۵');
    expect(formatIsoDate('2026-12-01', long: false), '۱۴۰۵/۰۹/۱۰');
    expect(formatIsoDate('not-a-date'), emptyPlaceholder);
    expect(formatIsoDate(null), emptyPlaceholder);
  });

  test('formats durations', () {
    expect(formatDuration(0), '۰ ثانیه');
    expect(formatDuration(45), '۴۵ ثانیه');
    expect(formatDuration(60), '۱ دقیقه');
    expect(formatDuration(1800), '۳۰ دقیقه');
    expect(formatDuration(3600), '۱ ساعت');
    expect(formatDuration(5400), '۱ ساعت و ۳۰ دقیقه');
    expect(formatDuration(-5), '۰ ثانیه');
    expect(formatDuration(null), '۰ ثانیه');
  });

  test('formats goods field values by type', () {
    expect(formatFieldValue('TEXT', 'یخچال'), 'یخچال');
    expect(formatFieldValue('NUMBER', 24), '۲۴');
    expect(formatFieldValue('DECIMAL', '1250.5'), '۱٬۲۵۰٫۵');
    expect(formatFieldValue('DATE', '2026-12-01'), '۱۰ آذر ۱۴۰۵');
    expect(formatFieldValue('BOOLEAN', true), 'بله');
    expect(formatFieldValue('BOOLEAN', false), 'خیر');
    expect(formatFieldValue('SELECT', 'پالت'), 'پالت');
    expect(formatFieldValue('MULTI_SELECT', ['بیمه', 'بارگیری']), 'بیمه، بارگیری');
    expect(formatFieldValue('DATETIME', '2026-11-10T10:39:00Z'), contains('آبان ۱۴۰۵، ساعت'));
    for (final empty in [null, '', <String>[]]) {
      expect(formatFieldValue('TEXT', empty), emptyPlaceholder);
    }
    expect(fieldTypeLabels.keys, hasLength(8));
  });
}
