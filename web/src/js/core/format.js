/** Presentation helpers: Persian digits, Jalali dates, file sizes and typed product values. */

import { JALALI_MONTH_NAMES, isoDateToJalali, toJalali } from './jalali.js';

const PERSIAN_DIGITS = '۰۱۲۳۴۵۶۷۸۹';
const THOUSANDS_SEPARATOR = '٬';
const DECIMAL_SEPARATOR = '٫';
export const EMPTY_PLACEHOLDER = '—';

export function toPersianDigits(value) {
  return String(value).replace(/\d/g, (digit) => PERSIAN_DIGITS[Number(digit)]);
}

/** Persian (۰-۹) and Arabic-Indic (٠-٩) digits → ASCII digits; other characters are kept. */
export function toLatinDigits(value) {
  return String(value)
    .replace(/[۰-۹]/g, (digit) => String(digit.charCodeAt(0) - 0x06f0))
    .replace(/[٠-٩]/g, (digit) => String(digit.charCodeAt(0) - 0x0660));
}

const LEFT_TO_RIGHT_ISOLATE = '\u2066';
const POP_DIRECTIONAL_ISOLATE = '\u2069';

/**
 * Formats a decimal number given as text ("-1250.50") without going through floating
 * point, so values keep exactly the digits the server returned.
 */
export function formatDecimalText(text) {
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(String(text).trim());
  if (!match) return toPersianDigits(String(text));
  const [, sign, integer, fraction] = match;
  const grouped = integer.replace(/\B(?=(\d{3})+(?!\d))/g, THOUSANDS_SEPARATOR);
  const digits = toPersianDigits(`${grouped}${fraction ? DECIMAL_SEPARATOR + fraction : ''}`);
  // In right-to-left text the minus sign would be drawn to the right of the digits; the isolate keeps it on the left.
  return sign === '-' ? `${LEFT_TO_RIGHT_ISOLATE}−${digits}${POP_DIRECTIONAL_ISOLATE}` : digits;
}

export function formatNumber(value) {
  if (value === null || value === undefined || value === '') return EMPTY_PLACEHOLDER;
  if (typeof value === 'number' && !Number.isFinite(value)) return EMPTY_PLACEHOLDER;
  return formatDecimalText(typeof value === 'number' ? value.toLocaleString('en-US', { useGrouping: false, maximumFractionDigits: 20 }) : value);
}

const SIZE_UNITS = ['بایت', 'کیلوبایت', 'مگابایت', 'گیگابایت'];

export function formatFileSize(bytes) {
  if (typeof bytes !== 'number' || !Number.isFinite(bytes) || bytes < 0) return EMPTY_PLACEHOLDER;
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < SIZE_UNITS.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const rounded = unit === 0 || value >= 100 ? Math.round(value) : Math.round(value * 10) / 10;
  return `${formatDecimalText(String(rounded))} ${SIZE_UNITS[unit]}`;
}

const pad = (value) => String(value).padStart(2, '0');

function parseInstant(value) {
  if (value === null || value === undefined || value === '') return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function dateParts(date, utc) {
  return utc
    ? { y: date.getUTCFullYear(), m: date.getUTCMonth() + 1, d: date.getUTCDate(), h: date.getUTCHours(), min: date.getUTCMinutes() }
    : { y: date.getFullYear(), m: date.getMonth() + 1, d: date.getDate(), h: date.getHours(), min: date.getMinutes() };
}

function jalaliText({ jy, jm, jd }, style) {
  return style === 'long'
    ? toPersianDigits(`${jd} ${JALALI_MONTH_NAMES[jm - 1]} ${jy}`)
    : toPersianDigits(`${jy}/${pad(jm)}/${pad(jd)}`);
}

/**
 * Formats an instant (ISO 8601 text or Date) as a Jalali date in the viewer's time zone.
 * Options: `style` "numeric" (۱۴۰۵/۰۸/۱۹) or "long" (۱۹ آبان ۱۴۰۵); `utc` to ignore the local zone.
 */
export function formatDate(value, { style = 'numeric', utc = false } = {}) {
  const date = parseInstant(value);
  if (!date) return EMPTY_PLACEHOLDER;
  const parts = dateParts(date, utc);
  return jalaliText(toJalali(parts.y, parts.m, parts.d), style);
}

export function formatTime(value, { utc = false } = {}) {
  const date = parseInstant(value);
  if (!date) return EMPTY_PLACEHOLDER;
  const parts = dateParts(date, utc);
  return toPersianDigits(`${pad(parts.h)}:${pad(parts.min)}`);
}

export function formatDateTime(value, options = {}) {
  const date = parseInstant(value);
  if (!date) return EMPTY_PLACEHOLDER;
  const separator = options.style === 'long' ? '، ساعت ' : '، ';
  return `${formatDate(date, options)}${separator}${formatTime(date, options)}`;
}

/** Formats a calendar date ("YYYY-MM-DD") that has no time zone, e.g. a DATE product field. */
export function formatIsoDate(isoDate, { style = 'long' } = {}) {
  const jalali = isoDateToJalali(isoDate);
  return jalali ? jalaliText(jalali, style) : EMPTY_PLACEHOLDER;
}

/** "about N minutes" style text for short durations given in seconds. */
export function formatDuration(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  if (total < 60) return `${toPersianDigits(total)} ثانیه`;
  const minutes = Math.round(total / 60);
  if (minutes < 60) return `${toPersianDigits(minutes)} دقیقه`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest ? `${toPersianDigits(hours)} ساعت و ${toPersianDigits(rest)} دقیقه` : `${toPersianDigits(hours)} ساعت`;
}

export const FIELD_TYPE_LABELS = Object.freeze({
  TEXT: 'متن',
  NUMBER: 'عدد صحیح',
  DECIMAL: 'عدد اعشاری',
  DATE: 'تاریخ',
  DATETIME: 'تاریخ و زمان',
  BOOLEAN: 'بله / خیر',
  SELECT: 'انتخاب تکی',
  MULTI_SELECT: 'انتخاب چندتایی',
});

/**
 * Human-readable text of a product-field value.
 * `value` is the display value returned by the API (option labels for select fields).
 */
export function formatFieldValue(dataType, value) {
  if (value === null || value === undefined || value === '' || (Array.isArray(value) && value.length === 0)) {
    return EMPTY_PLACEHOLDER;
  }
  switch (dataType) {
    case 'NUMBER':
    case 'DECIMAL':
      return formatNumber(value);
    case 'DATE':
      return formatIsoDate(value);
    case 'DATETIME':
      return formatDateTime(value, { style: 'long' });
    case 'BOOLEAN':
      return value === true ? 'بله' : 'خیر';
    case 'MULTI_SELECT':
      return Array.isArray(value) ? value.join('، ') : String(value);
    default:
      return String(value);
  }
}
