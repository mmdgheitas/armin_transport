import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  isJalaliLeapYear,
  isValidGregorianDate,
  isValidJalaliDate,
  isoDateToJalali,
  jalaliMonthLength,
  jalaliToIsoDate,
  toGregorian,
  toJalali,
} from '../../src/js/core/jalali.js';

test('converts well-known dates in both directions', () => {
  const pairs = [
    [[2024, 3, 20], [1403, 1, 1]], // Nowruz 1403
    [[2025, 3, 20], [1403, 12, 30]], // last day of a leap year
    [[2025, 3, 21], [1404, 1, 1]],
    [[2026, 3, 21], [1405, 1, 1]],
    [[2026, 11, 10], [1405, 8, 19]],
    [[2021, 3, 20], [1399, 12, 30]],
    [[1979, 2, 11], [1357, 11, 22]],
    [[2000, 1, 1], [1378, 10, 11]],
    [[2026, 12, 1], [1405, 9, 10]],
  ];
  for (const [[gy, gm, gd], [jy, jm, jd]] of pairs) {
    assert.deepEqual(toJalali(gy, gm, gd), { jy, jm, jd }, `${gy}-${gm}-${gd}`);
    assert.deepEqual(toGregorian(jy, jm, jd), { gy, gm, gd }, `${jy}/${jm}/${jd}`);
  }
});

test('agrees with the ICU Persian calendar for every day from 1900 to 2100', () => {
  const icu = new Intl.DateTimeFormat('en-US-u-ca-persian-nu-latn', {
    timeZone: 'UTC',
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
  });
  const end = Date.UTC(2100, 11, 31);
  let checked = 0;
  for (let time = Date.UTC(1900, 0, 1); time <= end; time += 86_400_000) {
    const date = new Date(time);
    const parts = Object.fromEntries(icu.formatToParts(date).map((part) => [part.type, part.value]));
    const expected = { jy: Number(parts.year), jm: Number(parts.month), jd: Number(parts.day) };
    const actual = toJalali(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate());
    if (actual.jy !== expected.jy || actual.jm !== expected.jm || actual.jd !== expected.jd) {
      assert.fail(`${date.toISOString().slice(0, 10)}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
    const back = toGregorian(actual.jy, actual.jm, actual.jd);
    if (back.gy !== date.getUTCFullYear() || back.gm !== date.getUTCMonth() + 1 || back.gd !== date.getUTCDate()) {
      assert.fail(`round trip failed for ${date.toISOString().slice(0, 10)}`);
    }
    checked += 1;
  }
  assert.equal(checked, 73_414);
});

test('knows leap years and month lengths', () => {
  for (const year of [1370, 1375, 1379, 1383, 1387, 1391, 1395, 1399, 1403, 1408]) {
    assert.equal(isJalaliLeapYear(year), true, String(year));
    assert.equal(jalaliMonthLength(year, 12), 30);
  }
  for (const year of [1400, 1401, 1402, 1404, 1405, 1406, 1407]) {
    assert.equal(isJalaliLeapYear(year), false, String(year));
    assert.equal(jalaliMonthLength(year, 12), 29);
  }
  assert.equal(jalaliMonthLength(1405, 1), 31);
  assert.equal(jalaliMonthLength(1405, 6), 31);
  assert.equal(jalaliMonthLength(1405, 7), 30);
  assert.equal(jalaliMonthLength(1405, 11), 30);
});

test('validates dates', () => {
  assert.equal(isValidJalaliDate(1403, 12, 30), true);
  assert.equal(isValidJalaliDate(1404, 12, 30), false);
  assert.equal(isValidJalaliDate(1404, 7, 31), false);
  assert.equal(isValidJalaliDate(1404, 13, 1), false);
  assert.equal(isValidJalaliDate(1404, 0, 1), false);
  assert.equal(isValidJalaliDate(1404, 1, 0), false);
  assert.equal(isValidJalaliDate(1404.5, 1, 1), false);
  assert.equal(isValidJalaliDate(99999, 1, 1), false);
  assert.equal(isValidGregorianDate(2024, 2, 29), true);
  assert.equal(isValidGregorianDate(2023, 2, 29), false);
  assert.equal(isValidGregorianDate(1900, 2, 29), false);
  assert.equal(isValidGregorianDate(2000, 2, 29), true);
  assert.throws(() => toGregorian(1404, 12, 30), RangeError);
  assert.throws(() => toJalali(2023, 2, 30), RangeError);
});

test('converts ISO date text used by the API', () => {
  assert.deepEqual(isoDateToJalali('2026-12-01'), { jy: 1405, jm: 9, jd: 10 });
  assert.equal(jalaliToIsoDate(1405, 9, 10), '2026-12-01');
  assert.equal(jalaliToIsoDate(1403, 1, 1), '2024-03-20');
  assert.equal(jalaliToIsoDate(1404, 12, 30), null);
  for (const invalid of ['', null, undefined, '2026-13-01', '2026-02-30', '1405/09/10', '2026-1-1', 'abc']) {
    assert.equal(isoDateToJalali(invalid), null, String(invalid));
  }
});
