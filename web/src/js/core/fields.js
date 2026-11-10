/**
 * Conversion between dynamic product-field values as the API stores them and the
 * raw state of the form controls that edit them. Pure functions, no DOM access.
 *
 * API value formats: TEXT string · NUMBER integer · DECIMAL string · DATE "YYYY-MM-DD" ·
 * DATETIME ISO 8601 in UTC · BOOLEAN true/false · SELECT option value · MULTI_SELECT [option values].
 * `null` always means "no value".
 */

import { formatDateTime, formatIsoDate, formatNumber, toLatinDigits, toPersianDigits } from './format.js';

const pad = (value) => String(value).padStart(2, '0');

/** ISO instant → `{ date: "YYYY-MM-DD", time: "HH:MM" }` in the viewer's local time zone. */
export function instantToLocalParts(value) {
  const date = new Date(value);
  if (value === null || value === undefined || value === '' || Number.isNaN(date.getTime())) return { date: '', time: '' };
  return {
    date: `${String(date.getFullYear()).padStart(4, '0')}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`,
    time: `${pad(date.getHours())}:${pad(date.getMinutes())}`,
  };
}

/** Local `{ date, time }` → ISO instant in UTC, or `null` when either part is malformed. */
export function localPartsToInstant({ date, time }) {
  const dateMatch = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date ?? '');
  const timeMatch = /^(\d{1,2}):(\d{2})$/.exec(toLatinDigits(time ?? '').trim());
  if (!dateMatch || !timeMatch) return null;
  const [year, month, day] = dateMatch.slice(1).map(Number);
  const [hours, minutes] = timeMatch.slice(1).map(Number);
  if (hours > 23 || minutes > 59) return null;
  const local = new Date(year, month - 1, day, hours, minutes, 0, 0);
  if (local.getFullYear() !== year || local.getMonth() !== month - 1 || local.getDate() !== day) return null;
  return local.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** The initial state of the form control for `field`, given the value stored on the server. */
export function apiValueToInput(field, value) {
  switch (field.data_type) {
    case 'BOOLEAN':
      return value === true ? 'true' : value === false ? 'false' : '';
    case 'MULTI_SELECT':
      return Array.isArray(value) ? [...value] : [];
    case 'DATETIME':
      return instantToLocalParts(value);
    default:
      return value === null || value === undefined ? '' : String(value);
  }
}

function normalizeNumberText(text) {
  return toLatinDigits(text)
    .replace(/[٬,\s]/g, '') // thousands separators
    .replace(/[٫/]/g, '.') // Persian decimal separators
    .replace(/[−–]/g, '-');
}

/**
 * Converts the state of a form control into the value sent to the API.
 * Returns `{ value }` on success or `{ error }` with a Persian message. Only shape
 * problems are reported here; the rules of the field are enforced by the server
 * (`collectFieldValues` additionally checks date limits, see `dateLimitProblem`).
 */
export function inputToApiValue(field, input) {
  switch (field.data_type) {
    case 'TEXT':
    case 'SELECT':
    case 'DATE': {
      const text = String(input ?? '').trim();
      return { value: text === '' ? null : text };
    }
    case 'NUMBER': {
      const text = normalizeNumberText(String(input ?? '').trim());
      if (text === '') return { value: null };
      if (!/^-?\d+$/.test(text) || !Number.isSafeInteger(Number(text))) return { error: 'یک عدد صحیح معتبر وارد کنید.' };
      return { value: Number(text) };
    }
    case 'DECIMAL': {
      const text = normalizeNumberText(String(input ?? '').trim());
      if (text === '') return { value: null };
      if (!/^-?\d+(\.\d+)?$/.test(text)) return { error: 'یک عدد معتبر وارد کنید (مثلاً 12.5).' };
      return { value: text };
    }
    case 'BOOLEAN':
      return { value: input === 'true' ? true : input === 'false' ? false : null };
    case 'MULTI_SELECT':
      return { value: Array.isArray(input) && input.length > 0 ? [...input] : null };
    case 'DATETIME': {
      const { date = '', time = '' } = input ?? {};
      if (date === '' && String(time).trim() === '') return { value: null };
      if (date === '') return { error: 'تاریخ را کامل وارد کنید.' };
      const instant = localPartsToInstant({ date, time: String(time).trim() === '' ? '00:00' : time });
      return instant === null ? { error: 'ساعت را به شکل ۱۴:۳۰ وارد کنید.' } : { value: instant };
    }
    default:
      return { value: input ?? null };
  }
}

/**
 * A message when a date or date-time breaks the limits of its field, otherwise `null`.
 * The server enforces the same limits but can only name them as Gregorian dates,
 * so the client checks them first and names them in the user's calendar.
 */
function dateLimitProblem(field, value) {
  const { min, max } = field.validation_rules ?? {};
  if (field.data_type === 'DATE') {
    // ISO dates of the same length compare correctly as text.
    if (min !== undefined && value < min) return `تاریخ نباید قبل از ${formatIsoDate(min)} باشد.`;
    if (max !== undefined && value > max) return `تاریخ نباید بعد از ${formatIsoDate(max)} باشد.`;
  }
  if (field.data_type === 'DATETIME') {
    const instant = Date.parse(value);
    if (min !== undefined && instant < Date.parse(min)) return `زمان نباید قبل از ${formatDateTime(min)} باشد.`;
    if (max !== undefined && instant > Date.parse(max)) return `زمان نباید بعد از ${formatDateTime(max)} باشد.`;
  }
  return null;
}

/**
 * Collects API values for all `fields` from `inputs` (`{ field_key: control state }`).
 * Returns `{ values, errors }`; `errors` maps field keys to messages and is empty on success.
 */
export function collectFieldValues(fields, inputs) {
  const values = {};
  const errors = {};
  for (const field of fields) {
    const result = inputToApiValue(field, inputs[field.field_key]);
    const problem = result.error ?? (result.value === null ? (field.is_required ? 'وارد کردن این فیلد الزامی است.' : null) : dateLimitProblem(field, result.value));
    if (problem) errors[field.field_key] = problem;
    else values[field.field_key] = result.value;
  }
  return { values, errors };
}

/** Maps API validation errors ("values.weight") to field keys ("weight"). */
export function fieldErrorsFromApi(apiFields, prefix = 'values.') {
  const errors = {};
  for (const [name, messages] of Object.entries(apiFields ?? {})) {
    if (name.startsWith(prefix)) errors[name.slice(prefix.length)] = Array.isArray(messages) ? messages.join(' ') : String(messages);
  }
  return errors;
}

export const RULE_DEFINITIONS = Object.freeze({
  TEXT: [
    { key: 'min_length', label: 'حداقل طول', kind: 'integer' },
    { key: 'max_length', label: 'حداکثر طول', kind: 'integer' },
    { key: 'pattern', label: 'الگو (عبارت باقاعده)', kind: 'text' },
  ],
  NUMBER: [
    { key: 'min', label: 'حداقل مقدار', kind: 'integer' },
    { key: 'max', label: 'حداکثر مقدار', kind: 'integer' },
  ],
  DECIMAL: [
    { key: 'min', label: 'حداقل مقدار', kind: 'decimal' },
    { key: 'max', label: 'حداکثر مقدار', kind: 'decimal' },
    { key: 'max_decimal_places', label: 'حداکثر رقم اعشار', kind: 'integer' },
  ],
  DATE: [
    { key: 'min', label: 'از تاریخ', kind: 'date' },
    { key: 'max', label: 'تا تاریخ', kind: 'date' },
  ],
  DATETIME: [
    { key: 'min', label: 'از زمان', kind: 'datetime' },
    { key: 'max', label: 'تا زمان', kind: 'datetime' },
  ],
  BOOLEAN: [],
  SELECT: [],
  MULTI_SELECT: [
    { key: 'min_items', label: 'حداقل تعداد انتخاب', kind: 'integer' },
    { key: 'max_items', label: 'حداکثر تعداد انتخاب', kind: 'integer' },
  ],
});

const INVALID_RULE_DATE = 'تاریخ واردشده کامل یا معتبر نیست.';

/** The initial state of the form control that edits one validation rule. */
export function ruleValueToInput(kind, value) {
  if (kind === 'datetime') return instantToLocalParts(value);
  return value === null || value === undefined ? '' : String(value);
}

function parseRule(kind, raw) {
  if (kind === 'date') {
    // Date controls yield "" (empty), null (impossible date) or "YYYY-MM-DD".
    if (raw === null) return { error: INVALID_RULE_DATE };
    return raw === '' || raw === undefined ? {} : { value: raw };
  }
  if (kind === 'datetime') {
    if (raw === null) return { error: INVALID_RULE_DATE };
    if (raw === '' || raw === undefined || (raw.date === '' && String(raw.time ?? '').trim() === '')) return {};
    const instant = localPartsToInstant({ date: raw.date, time: String(raw.time ?? '').trim() === '' ? '00:00' : raw.time });
    return instant === null ? { error: INVALID_RULE_DATE } : { value: instant };
  }
  const text = String(raw ?? '').trim();
  if (text === '') return {};
  if (kind === 'integer') {
    const number = normalizeNumberText(text);
    return /^-?\d+$/.test(number) && Number.isSafeInteger(Number(number)) ? { value: Number(number) } : { error: 'یک عدد صحیح معتبر وارد کنید.' };
  }
  if (kind === 'decimal') {
    const number = normalizeNumberText(text);
    return /^-?\d+(\.\d+)?$/.test(number) ? { value: number } : { error: 'یک عدد معتبر وارد کنید.' };
  }
  return { value: text };
}

/**
 * Builds the `validation_rules` object of a field definition from the state of the rule controls.
 * Returns `{ rules }` (`null` when no rule is set) or `{ errors }` keyed by rule name.
 */
export function buildValidationRules(dataType, inputs) {
  const rules = {};
  const errors = {};
  for (const { key, kind } of RULE_DEFINITIONS[dataType] ?? []) {
    const result = parseRule(kind, inputs[key]);
    if (result.error) errors[key] = result.error;
    else if ('value' in result) rules[key] = result.value;
  }
  if (Object.keys(errors).length > 0) return { errors };
  return { rules: Object.keys(rules).length > 0 ? rules : null };
}

/** A short Persian description of a field's validation rules for use as an input hint, or `null`. */
export function describeRules(field) {
  const rules = field.validation_rules ?? {};
  const show = (value) => {
    if (field.data_type === 'DATE') return formatIsoDate(value);
    if (field.data_type === 'DATETIME') return formatDateTime(value);
    return formatNumber(value);
  };
  const isDate = field.data_type === 'DATE' || field.data_type === 'DATETIME';
  const parts = [];
  if (rules.min !== undefined) parts.push(`${isDate ? 'از' : 'حداقل'} ${show(rules.min)}`);
  if (rules.max !== undefined) parts.push(`${isDate ? 'تا' : 'حداکثر'} ${show(rules.max)}`);
  if (rules.min_length !== undefined) parts.push(`حداقل ${toPersianDigits(rules.min_length)} نویسه`);
  if (rules.max_length !== undefined) parts.push(`حداکثر ${toPersianDigits(rules.max_length)} نویسه`);
  if (rules.max_decimal_places !== undefined) parts.push(`تا ${toPersianDigits(rules.max_decimal_places)} رقم اعشار`);
  if (rules.min_items !== undefined) parts.push(`حداقل ${toPersianDigits(rules.min_items)} گزینه`);
  if (rules.max_items !== undefined) parts.push(`حداکثر ${toPersianDigits(rules.max_items)} گزینه`);
  return parts.length > 0 ? parts.join(' · ') : null;
}

/**
 * Reads the option editor rows (`[{ value, label }]` as typed) into the API shape.
 * Blank rows are dropped. Returns `{ options }` or `{ error }`.
 */
export function buildOptions(rows) {
  const options = [];
  const seen = new Set();
  for (const row of rows) {
    const value = String(row.value ?? '').trim();
    const label = String(row.label ?? '').trim();
    if (value === '' && label === '') continue;
    if (value === '' || label === '') return { error: 'برای هر گزینه هم مقدار و هم برچسب را وارد کنید.' };
    if (seen.has(value)) return { error: `مقدار گزینهٔ «${value}» تکراری است.` };
    seen.add(value);
    options.push({ value, label });
  }
  return options.length > 0 ? { options } : { error: 'برای فیلد انتخابی دست‌کم یک گزینه لازم است.' };
}
