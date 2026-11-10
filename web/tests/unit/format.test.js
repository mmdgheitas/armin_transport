import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  EMPTY_PLACEHOLDER,
  formatDate,
  formatDateTime,
  formatDecimalText,
  formatDuration,
  formatFieldValue,
  formatFileSize,
  formatIsoDate,
  formatNumber,
  formatTime,
  toLatinDigits,
  toPersianDigits,
} from '../../src/js/core/format.js';

test('converts digits between scripts', () => {
  assert.equal(toPersianDigits('ABC-0123456789'), 'ABC-۰۱۲۳۴۵۶۷۸۹');
  assert.equal(toPersianDigits(42), '۴۲');
  assert.equal(toLatinDigits('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
  assert.equal(toLatinDigits('٠١٢٣٤٥٦٧٨٩'), '0123456789');
  assert.equal(toLatinDigits('کد ۱۲-AB'), 'کد 12-AB');
});

test('formats numbers without floating point artefacts', () => {
  assert.equal(formatNumber(0), '۰');
  assert.equal(formatNumber(1234567), '۱٬۲۳۴٬۵۶۷');
  // A negative number is isolated as left-to-right text so that its sign stays on the left of the digits.
  assert.equal(formatNumber(-1500), '\u2066−۱٬۵۰۰\u2069');
  assert.equal(formatNumber('-0.5'), '\u2066−۰٫۵\u2069');
  assert.equal(formatNumber('1250.5'), '۱٬۲۵۰٫۵');
  assert.equal(formatNumber('0.1000'), '۰٫۱۰۰۰');
  assert.equal(formatDecimalText('123456789012345678901234567890.123456789'), '۱۲۳٬۴۵۶٬۷۸۹٬۰۱۲٬۳۴۵٬۶۷۸٬۹۰۱٬۲۳۴٬۵۶۷٬۸۹۰٫۱۲۳۴۵۶۷۸۹');
  assert.equal(formatNumber(null), EMPTY_PLACEHOLDER);
  assert.equal(formatNumber(''), EMPTY_PLACEHOLDER);
  assert.equal(formatNumber(Number.NaN), EMPTY_PLACEHOLDER);
  assert.equal(formatNumber('not a number'), 'not a number');
});

test('formats file sizes', () => {
  assert.equal(formatFileSize(0), '۰ بایت');
  assert.equal(formatFileSize(1023), '۱٬۰۲۳ بایت');
  assert.equal(formatFileSize(1024), '۱ کیلوبایت');
  assert.equal(formatFileSize(1536), '۱٫۵ کیلوبایت');
  assert.equal(formatFileSize(10 * 1024 * 1024), '۱۰ مگابایت');
  assert.equal(formatFileSize(3.25 * 1024 * 1024 * 1024), '۳٫۳ گیگابایت');
  assert.equal(formatFileSize(-1), EMPTY_PLACEHOLDER);
  assert.equal(formatFileSize(undefined), EMPTY_PLACEHOLDER);
});

test('formats instants as Jalali dates', () => {
  const instant = '2026-11-10T10:39:05.123Z';
  assert.equal(formatDate(instant, { utc: true }), '۱۴۰۵/۰۸/۱۹');
  assert.equal(formatDate(instant, { utc: true, style: 'long' }), '۱۹ آبان ۱۴۰۵');
  assert.equal(formatTime(instant, { utc: true }), '۱۰:۳۹');
  assert.equal(formatDateTime(instant, { utc: true }), '۱۴۰۵/۰۸/۱۹، ۱۰:۳۹');
  assert.equal(formatDateTime(instant, { utc: true, style: 'long' }), '۱۹ آبان ۱۴۰۵، ساعت ۱۰:۳۹');
  assert.equal(formatDate(new Date(Date.UTC(2024, 2, 20)), { utc: true }), '۱۴۰۳/۰۱/۰۱');
  for (const invalid of [null, undefined, '', 'garbage']) {
    assert.equal(formatDate(invalid), EMPTY_PLACEHOLDER);
    assert.equal(formatDateTime(invalid), EMPTY_PLACEHOLDER);
    assert.equal(formatTime(invalid), EMPTY_PLACEHOLDER);
  }
});

test('uses the local time zone by default', () => {
  const local = new Date(2026, 10, 10, 23, 59); // 10 Nov 2026, 23:59 local time
  assert.equal(formatDateTime(local), '۱۴۰۵/۰۸/۱۹، ۲۳:۵۹');
});

test('formats calendar dates without time zone shifts', () => {
  assert.equal(formatIsoDate('2026-12-01'), '۱۰ آذر ۱۴۰۵');
  assert.equal(formatIsoDate('2026-12-01', { style: 'numeric' }), '۱۴۰۵/۰۹/۱۰');
  assert.equal(formatIsoDate('not-a-date'), EMPTY_PLACEHOLDER);
});

test('formats durations', () => {
  assert.equal(formatDuration(0), '۰ ثانیه');
  assert.equal(formatDuration(45), '۴۵ ثانیه');
  assert.equal(formatDuration(60), '۱ دقیقه');
  assert.equal(formatDuration(1800), '۳۰ دقیقه');
  assert.equal(formatDuration(3600), '۱ ساعت');
  assert.equal(formatDuration(5400), '۱ ساعت و ۳۰ دقیقه');
  assert.equal(formatDuration(-5), '۰ ثانیه');
});

test('formats product field values by type', () => {
  assert.equal(formatFieldValue('TEXT', 'یخچال'), 'یخچال');
  assert.equal(formatFieldValue('NUMBER', 24), '۲۴');
  assert.equal(formatFieldValue('DECIMAL', '1250.5'), '۱٬۲۵۰٫۵');
  assert.equal(formatFieldValue('DATE', '2026-12-01'), '۱۰ آذر ۱۴۰۵');
  assert.equal(formatFieldValue('BOOLEAN', true), 'بله');
  assert.equal(formatFieldValue('BOOLEAN', false), 'خیر');
  assert.equal(formatFieldValue('SELECT', 'پالت'), 'پالت');
  assert.equal(formatFieldValue('MULTI_SELECT', ['بیمه', 'بارگیری']), 'بیمه، بارگیری');
  assert.match(formatFieldValue('DATETIME', '2026-11-10T10:39:00Z'), /آبان ۱۴۰۵، ساعت/);
  for (const empty of [null, undefined, '', []]) {
    assert.equal(formatFieldValue('TEXT', empty), EMPTY_PLACEHOLDER);
  }
});
