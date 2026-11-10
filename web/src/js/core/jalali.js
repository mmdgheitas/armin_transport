/**
 * Conversion between the Gregorian and the Jalali (Persian, Solar Hijri) calendar.
 *
 * The algorithm follows the arithmetic rules published by Kazimierz M. Borkowski
 * (the same rules used by the widely deployed "jalaali" libraries) and is valid for
 * Jalali years -61 to 3177. All functions are pure; months are 1-based.
 */

const BREAKS = [-61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178];

export const JALALI_MONTH_NAMES = Object.freeze([
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
]);

export const MIN_JALALI_YEAR = BREAKS[0];
export const MAX_JALALI_YEAR = BREAKS[BREAKS.length - 1] - 1;

const div = (a, b) => Math.trunc(a / b);
const mod = (a, b) => a - Math.trunc(a / b) * b;

/** Leap-cycle data of a Jalali year: years since the last leap year, Gregorian year and day of March of 1 Farvardin. */
function jalaliCalendar(jy) {
  if (!Number.isInteger(jy) || jy < MIN_JALALI_YEAR || jy > MAX_JALALI_YEAR) {
    throw new RangeError(`Jalali year out of range: ${jy}`);
  }
  const gy = jy + 621;
  let leapJ = -14;
  let jp = BREAKS[0];
  let jump = 0;
  for (let i = 1; i < BREAKS.length; i += 1) {
    const jm = BREAKS[i];
    jump = jm - jp;
    if (jy < jm) break;
    leapJ += div(jump, 33) * 8 + div(mod(jump, 33), 4);
    jp = jm;
  }
  let n = jy - jp;
  leapJ += div(n, 33) * 8 + div(mod(n, 33) + 3, 4);
  if (mod(jump, 33) === 4 && jump - n === 4) leapJ += 1;
  const leapG = div(gy, 4) - div((div(gy, 100) + 1) * 3, 4) - 150;
  const march = 20 + leapJ - leapG;
  if (jump - n < 6) n = n - jump + div(jump + 4, 33) * 33;
  let leap = mod(mod(n + 1, 33) - 1, 4);
  if (leap === -1) leap = 4;
  return { leap, gy, march };
}

/** Julian day number of a Gregorian date. */
function gregorianToDayNumber(gy, gm, gd) {
  const d =
    div((gy + div(gm - 8, 6) + 100100) * 1461, 4) + div(153 * mod(gm + 9, 12) + 2, 5) + gd - 34840408;
  return d - div(div(gy + 100100 + div(gm - 8, 6), 100) * 3, 4) + 752;
}

function dayNumberToGregorian(jdn) {
  let j = 4 * jdn + 139361631;
  j = j + div(div(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
  const i = div(mod(j, 1461), 4) * 5 + 308;
  const gd = div(mod(i, 153), 5) + 1;
  const gm = mod(div(i, 153), 12) + 1;
  const gy = div(j, 1461) - 100100 + div(8 - gm, 6);
  return { gy, gm, gd };
}

function jalaliToDayNumber(jy, jm, jd) {
  const calendar = jalaliCalendar(jy);
  return gregorianToDayNumber(calendar.gy, 3, calendar.march) + (jm - 1) * 31 - div(jm, 7) * (jm - 7) + jd - 1;
}

function dayNumberToJalali(jdn) {
  const { gy } = dayNumberToGregorian(jdn);
  let jy = gy - 621;
  const calendar = jalaliCalendar(jy);
  let k = jdn - gregorianToDayNumber(gy, 3, calendar.march);
  if (k >= 0) {
    if (k <= 185) return { jy, jm: 1 + div(k, 31), jd: mod(k, 31) + 1 };
    k -= 186;
  } else {
    jy -= 1;
    k += 179;
    if (calendar.leap === 1) k += 1;
  }
  return { jy, jm: 7 + div(k, 30), jd: mod(k, 30) + 1 };
}

export function isJalaliLeapYear(jy) {
  return jalaliCalendar(jy).leap === 0;
}

export function jalaliMonthLength(jy, jm) {
  if (jm <= 6) return 31;
  if (jm <= 11) return 30;
  return isJalaliLeapYear(jy) ? 30 : 29;
}

export function isValidJalaliDate(jy, jm, jd) {
  return (
    Number.isInteger(jy) &&
    Number.isInteger(jm) &&
    Number.isInteger(jd) &&
    jy >= MIN_JALALI_YEAR &&
    jy <= MAX_JALALI_YEAR &&
    jm >= 1 &&
    jm <= 12 &&
    jd >= 1 &&
    jd <= jalaliMonthLength(jy, jm)
  );
}

export function isValidGregorianDate(gy, gm, gd) {
  if (!Number.isInteger(gy) || !Number.isInteger(gm) || !Number.isInteger(gd)) return false;
  if (gm < 1 || gm > 12 || gd < 1) return false;
  const leap = (gy % 4 === 0 && gy % 100 !== 0) || gy % 400 === 0;
  const lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return gd <= lengths[gm - 1];
}

/** Gregorian → Jalali. Returns `{ jy, jm, jd }`. */
export function toJalali(gy, gm, gd) {
  if (!isValidGregorianDate(gy, gm, gd)) throw new RangeError(`Invalid Gregorian date: ${gy}-${gm}-${gd}`);
  return dayNumberToJalali(gregorianToDayNumber(gy, gm, gd));
}

/** Jalali → Gregorian. Returns `{ gy, gm, gd }`. */
export function toGregorian(jy, jm, jd) {
  if (!isValidJalaliDate(jy, jm, jd)) throw new RangeError(`Invalid Jalali date: ${jy}/${jm}/${jd}`);
  return dayNumberToGregorian(jalaliToDayNumber(jy, jm, jd));
}

const pad = (value, length = 2) => String(value).padStart(length, '0');

/** "YYYY-MM-DD" (Gregorian, as used by the API) → `{ jy, jm, jd }`, or `null` when the text is not a valid date. */
export function isoDateToJalali(isoDate) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(isoDate ?? '').trim());
  if (!match) return null;
  const [gy, gm, gd] = match.slice(1).map(Number);
  return isValidGregorianDate(gy, gm, gd) ? toJalali(gy, gm, gd) : null;
}

/** `{ jy, jm, jd }` → "YYYY-MM-DD" (Gregorian), or `null` when the Jalali date does not exist. */
export function jalaliToIsoDate(jy, jm, jd) {
  if (!isValidJalaliDate(jy, jm, jd)) return null;
  const { gy, gm, gd } = toGregorian(jy, jm, jd);
  return `${pad(gy, 4)}-${pad(gm)}-${pad(gd)}`;
}
