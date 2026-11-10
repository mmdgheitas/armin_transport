/**
 * Tracking-code normalization, mirroring the backend rules so users get instant feedback.
 * The server remains the authority: it normalizes and validates every code again.
 */

import { toLatinDigits, toPersianDigits } from './format.js';

const DASH_VARIANTS = /[\u2010-\u2015\u2212]/g;
const INVISIBLE = /[\s\u200b-\u200f\u2060\ufeff]/g;

export const DEFAULT_TRACKING_CODE_RULES = Object.freeze({
  min_length: 6,
  max_length: 64,
  pattern: '^[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?$',
});

export function normalizeTrackingCode(raw) {
  return toLatinDigits(String(raw ?? '').normalize('NFKC'))
    .replace(DASH_VARIANTS, '-')
    .replace(INVISIBLE, '')
    .toUpperCase();
}

/** Returns a Persian error message, or `null` when the (already normalized) code is acceptable. */
export function trackingCodeProblem(code, rules = DEFAULT_TRACKING_CODE_RULES) {
  const { min_length: min, max_length: max, pattern } = { ...DEFAULT_TRACKING_CODE_RULES, ...rules };
  if (code.length === 0) return 'کد رهگیری را وارد کنید.';
  if (code.length < min) return `کد رهگیری باید دست‌کم ${toPersianDigits(min)} نویسه باشد.`;
  if (code.length > max) return `کد رهگیری نباید بیشتر از ${toPersianDigits(max)} نویسه باشد.`;
  if (!new RegExp(pattern).test(code)) {
    return 'کد رهگیری فقط می‌تواند شامل حروف انگلیسی، رقم و خط تیره باشد و نباید با خط تیره شروع یا تمام شود.';
  }
  return null;
}
