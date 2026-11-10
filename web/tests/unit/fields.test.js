import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  RULE_DEFINITIONS,
  apiValueToInput,
  buildOptions,
  buildValidationRules,
  collectFieldValues,
  describeRules,
  fieldErrorsFromApi,
  inputToApiValue,
  instantToLocalParts,
  localPartsToInstant,
  ruleValueToInput,
} from '../../src/js/core/fields.js';

const field = (data_type, extra = {}) => ({ field_key: data_type.toLowerCase(), data_type, is_required: false, ...extra });

test('converts control state to API values', () => {
  assert.deepEqual(inputToApiValue(field('TEXT'), '  یخچال  '), { value: 'یخچال' });
  assert.deepEqual(inputToApiValue(field('TEXT'), '   '), { value: null });
  assert.deepEqual(inputToApiValue(field('NUMBER'), '۲۴'), { value: 24 });
  assert.deepEqual(inputToApiValue(field('NUMBER'), '1٬250'), { value: 1250 });
  assert.deepEqual(inputToApiValue(field('NUMBER'), '-7'), { value: -7 });
  assert.deepEqual(inputToApiValue(field('NUMBER'), ''), { value: null });
  assert.ok(inputToApiValue(field('NUMBER'), '12.5').error);
  assert.ok(inputToApiValue(field('NUMBER'), 'abc').error);
  assert.ok(inputToApiValue(field('NUMBER'), '99999999999999999999').error);
  assert.deepEqual(inputToApiValue(field('DECIMAL'), '۱۲۵۰٫۵'), { value: '1250.5' });
  assert.deepEqual(inputToApiValue(field('DECIMAL'), '1,250.50'), { value: '1250.50' });
  assert.deepEqual(inputToApiValue(field('DECIMAL'), '12/5'), { value: '12.5' }); // "/" is the usual decimal key on Persian keyboards
  assert.deepEqual(inputToApiValue(field('DECIMAL'), '0.1000000000000000000000001'), { value: '0.1000000000000000000000001' });
  assert.ok(inputToApiValue(field('DECIMAL'), '1.2.3').error);
  assert.deepEqual(inputToApiValue(field('DATE'), '2026-12-01'), { value: '2026-12-01' });
  assert.deepEqual(inputToApiValue(field('DATE'), ''), { value: null });
  assert.deepEqual(inputToApiValue(field('BOOLEAN'), 'true'), { value: true });
  assert.deepEqual(inputToApiValue(field('BOOLEAN'), 'false'), { value: false });
  assert.deepEqual(inputToApiValue(field('BOOLEAN'), ''), { value: null });
  assert.deepEqual(inputToApiValue(field('SELECT'), 'pallet'), { value: 'pallet' });
  assert.deepEqual(inputToApiValue(field('SELECT'), ''), { value: null });
  assert.deepEqual(inputToApiValue(field('MULTI_SELECT'), ['a', 'b']), { value: ['a', 'b'] });
  assert.deepEqual(inputToApiValue(field('MULTI_SELECT'), []), { value: null });
});

test('converts date-time controls through the local time zone', () => {
  const instant = localPartsToInstant({ date: '2026-11-10', time: '14:30' });
  assert.equal(instant, new Date(2026, 10, 10, 14, 30).toISOString().replace('.000Z', 'Z'));
  assert.match(instant, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$/);
  assert.deepEqual(instantToLocalParts(instant), { date: '2026-11-10', time: '14:30' });
  assert.deepEqual(instantToLocalParts(null), { date: '', time: '' });
  assert.deepEqual(instantToLocalParts('garbage'), { date: '', time: '' });
  assert.equal(localPartsToInstant({ date: '2026-11-10', time: '۱۴:۳۰' }), instant); // Persian digits are accepted
  assert.equal(localPartsToInstant({ date: '2026-11-10', time: '24:00' }), null);
  assert.equal(localPartsToInstant({ date: '2026-11-10', time: '12:60' }), null);
  assert.equal(localPartsToInstant({ date: '2026-02-30', time: '10:00' }), null);
  assert.equal(localPartsToInstant({ date: '', time: '10:00' }), null);

  const datetime = field('DATETIME');
  assert.deepEqual(inputToApiValue(datetime, { date: '', time: '' }), { value: null });
  assert.deepEqual(inputToApiValue(datetime, { date: '2026-11-10', time: '14:30' }), { value: instant });
  assert.deepEqual(inputToApiValue(datetime, { date: '2026-11-10', time: '' }), {
    value: localPartsToInstant({ date: '2026-11-10', time: '00:00' }),
  });
  assert.ok(inputToApiValue(datetime, { date: '', time: '10:00' }).error);
  assert.ok(inputToApiValue(datetime, { date: '2026-11-10', time: 'noon' }).error);
});

test('converts API values to initial control state', () => {
  assert.equal(apiValueToInput(field('TEXT'), 'متن'), 'متن');
  assert.equal(apiValueToInput(field('TEXT'), null), '');
  assert.equal(apiValueToInput(field('NUMBER'), 24), '24');
  assert.equal(apiValueToInput(field('NUMBER'), 0), '0');
  assert.equal(apiValueToInput(field('DECIMAL'), '1250.5'), '1250.5');
  assert.equal(apiValueToInput(field('BOOLEAN'), true), 'true');
  assert.equal(apiValueToInput(field('BOOLEAN'), false), 'false');
  assert.equal(apiValueToInput(field('BOOLEAN'), null), '');
  const selected = ['a'];
  const copy = apiValueToInput(field('MULTI_SELECT'), selected);
  assert.deepEqual(copy, ['a']);
  assert.notEqual(copy, selected);
  assert.deepEqual(apiValueToInput(field('MULTI_SELECT'), null), []);
  assert.deepEqual(apiValueToInput(field('DATETIME'), null), { date: '', time: '' });
});

test('round-trips every type', () => {
  const samples = [
    [field('TEXT'), 'نام کالا'],
    [field('NUMBER'), 24],
    [field('DECIMAL'), '1250.5'],
    [field('DATE'), '2026-12-01'],
    [field('BOOLEAN'), false],
    [field('SELECT'), 'pallet'],
    [field('MULTI_SELECT'), ['insurance', 'loading']],
    [field('DATETIME'), '2026-11-10T10:39:00Z'],
  ];
  for (const [definition, value] of samples) {
    assert.deepEqual(inputToApiValue(definition, apiValueToInput(definition, value)), { value }, definition.data_type);
  }
});

test('collects a complete value set and reports missing required fields', () => {
  const fields = [
    { field_key: 'name', data_type: 'TEXT', is_required: true },
    { field_key: 'count', data_type: 'NUMBER', is_required: false },
    { field_key: 'weight', data_type: 'DECIMAL', is_required: false },
    { field_key: 'fragile', data_type: 'BOOLEAN', is_required: true },
  ];
  assert.deepEqual(collectFieldValues(fields, { name: 'یخچال', count: '', weight: '12.5', fragile: 'false' }), {
    values: { name: 'یخچال', count: null, weight: '12.5', fragile: false }, // cleared fields are sent as null
    errors: {},
  });
  const invalid = collectFieldValues(fields, { name: ' ', count: 'x', weight: '', fragile: '' });
  assert.deepEqual(Object.keys(invalid.errors).sort(), ['count', 'fragile', 'name']);
  assert.match(invalid.errors.name, /الزامی/);
  assert.match(invalid.errors.count, /عدد صحیح/);
});

test('names a broken date limit in the Jalali calendar before anything is sent', () => {
  const delivery = { field_key: 'delivery', data_type: 'DATE', is_required: false, validation_rules: { min: '2026-03-21', max: '2026-12-31' } };
  assert.deepEqual(collectFieldValues([delivery], { delivery: '2026-03-21' }), { values: { delivery: '2026-03-21' }, errors: {} });
  assert.deepEqual(collectFieldValues([delivery], { delivery: '2026-03-20' }).errors, { delivery: 'تاریخ نباید قبل از ۱ فروردین ۱۴۰۵ باشد.' });
  assert.deepEqual(collectFieldValues([delivery], { delivery: '2027-01-01' }).errors, { delivery: 'تاریخ نباید بعد از ۱۰ دی ۱۴۰۵ باشد.' });
  assert.deepEqual(collectFieldValues([delivery], { delivery: '' }), { values: { delivery: null }, errors: {} });

  const pickup = { field_key: 'pickup', data_type: 'DATETIME', is_required: false, validation_rules: { min: '2026-06-01T08:00:00.000Z', max: '2026-06-01T18:00:00.000Z' } };
  const at = (time) => ({ date: instantToLocalParts(time).date, time: instantToLocalParts(time).time });
  assert.deepEqual(collectFieldValues([pickup], { pickup: at('2026-06-01T08:00:00.000Z') }).errors, {});
  assert.match(collectFieldValues([pickup], { pickup: at('2026-06-01T07:59:00.000Z') }).errors.pickup, /^زمان نباید قبل از .+ باشد\.$/);
  assert.match(collectFieldValues([pickup], { pickup: at('2026-06-01T18:01:00.000Z') }).errors.pickup, /^زمان نباید بعد از .+ باشد\.$/);
});

test('maps API validation errors back to field keys', () => {
  assert.deepEqual(
    fieldErrorsFromApi({ 'values.weight': ['مقدار باید دست‌کم 0 باشد.'], 'values.name': ['الف', 'ب'], description: ['نامعتبر'] }),
    { weight: 'مقدار باید دست‌کم 0 باشد.', name: 'الف ب' },
  );
  assert.deepEqual(fieldErrorsFromApi(undefined), {});
  assert.deepEqual(fieldErrorsFromApi({ 'product_values.x': ['e'] }, 'product_values.'), { x: 'e' });
});

test('builds validation rules for field definitions', () => {
  assert.deepEqual(buildValidationRules('TEXT', { min_length: '۲', max_length: '200', pattern: ' ^[A-Z]+$ ' }), {
    rules: { min_length: 2, max_length: 200, pattern: '^[A-Z]+$' },
  });
  assert.deepEqual(buildValidationRules('TEXT', { min_length: '', max_length: '', pattern: '' }), { rules: null });
  assert.deepEqual(buildValidationRules('DECIMAL', { min: '0', max: '۱۰۰٫۵', max_decimal_places: '3' }), {
    rules: { min: '0', max: '100.5', max_decimal_places: 3 },
  });
  assert.deepEqual(buildValidationRules('DATE', { min: '2026-01-01', max: '' }), { rules: { min: '2026-01-01' } });
  assert.deepEqual(buildValidationRules('BOOLEAN', { min: '1' }), { rules: null }); // types without rules ignore stray input
  const invalid = buildValidationRules('NUMBER', { min: 'abc', max: '10' });
  assert.deepEqual(Object.keys(invalid.errors), ['min']);
  assert.equal(invalid.rules, undefined);
  assert.ok(buildValidationRules('MULTI_SELECT', { min_items: '1.5' }).errors.min_items);
});

test('builds date and date-time rules from the Jalali controls', () => {
  assert.deepEqual(buildValidationRules('DATE', { min: null, max: '2026-12-31' }), { errors: { min: 'تاریخ واردشده کامل یا معتبر نیست.' } });
  const instant = localPartsToInstant({ date: '2026-11-10', time: '08:00' });
  assert.deepEqual(buildValidationRules('DATETIME', { min: { date: '2026-11-10', time: '08:00' }, max: '' }), { rules: { min: instant } });
  assert.deepEqual(buildValidationRules('DATETIME', { min: { date: '2026-11-10', time: '' }, max: { date: '', time: '' } }), {
    rules: { min: localPartsToInstant({ date: '2026-11-10', time: '00:00' }) },
  });
  assert.ok(buildValidationRules('DATETIME', { min: null }).errors.min);
  assert.ok(buildValidationRules('DATETIME', { min: { date: '', time: '10:00' } }).errors.min);
  assert.deepEqual(buildValidationRules('DATETIME', {}), { rules: null });
  assert.deepEqual(buildValidationRules('SELECT', { anything: 'x' }), { rules: null });
});

test('every server rule key has an editor, and stored rules round-trip through it', () => {
  // Mirrors _RULE_NORMALIZERS in backend/app/modules/product_fields/validation.py.
  const serverRules = {
    TEXT: ['min_length', 'max_length', 'pattern'],
    NUMBER: ['min', 'max'],
    DECIMAL: ['min', 'max', 'max_decimal_places'],
    DATE: ['min', 'max'],
    DATETIME: ['min', 'max'],
    BOOLEAN: [],
    SELECT: [],
    MULTI_SELECT: ['min_items', 'max_items'],
  };
  for (const [type, keys] of Object.entries(serverRules)) {
    assert.deepEqual(RULE_DEFINITIONS[type].map((rule) => rule.key), keys, type);
  }

  const stored = {
    TEXT: { min_length: 2, max_length: 200, pattern: '^[A-Z]{2}\\d+$' },
    NUMBER: { min: -5, max: 100 },
    DECIMAL: { min: '0', max: '99999.5', max_decimal_places: 3 },
    DATE: { min: '2026-01-01', max: '2026-12-31' },
    DATETIME: { min: '2026-01-01T00:00:00Z', max: '2026-12-31T20:30:00Z' },
    MULTI_SELECT: { min_items: 1, max_items: 3 },
  };
  for (const [type, rules] of Object.entries(stored)) {
    const inputs = Object.fromEntries(RULE_DEFINITIONS[type].map(({ key, kind }) => [key, ruleValueToInput(kind, rules[key])]));
    assert.deepEqual(buildValidationRules(type, inputs), { rules }, type);
  }
  assert.equal(ruleValueToInput('integer', undefined), '');
  assert.equal(ruleValueToInput('integer', 0), '0');
  assert.deepEqual(ruleValueToInput('datetime', undefined), { date: '', time: '' });
});

test('describes rules as input hints', () => {
  assert.equal(describeRules({ data_type: 'TEXT', validation_rules: null }), null);
  assert.equal(describeRules({ data_type: 'BOOLEAN' }), null);
  assert.equal(describeRules({ data_type: 'TEXT', validation_rules: { min_length: 2, max_length: 200, pattern: 'x' } }), 'حداقل ۲ نویسه · حداکثر ۲۰۰ نویسه');
  assert.equal(describeRules({ data_type: 'NUMBER', validation_rules: { min: 0, max: 100000 } }), 'حداقل ۰ · حداکثر ۱۰۰٬۰۰۰');
  assert.equal(describeRules({ data_type: 'DECIMAL', validation_rules: { min: '0.5', max_decimal_places: 3 } }), 'حداقل ۰٫۵ · تا ۳ رقم اعشار');
  assert.equal(describeRules({ data_type: 'NUMBER', validation_rules: { min: -25, max: 8 } }), 'حداقل \u2066−۲۵\u2069 · حداکثر ۸');
  assert.equal(describeRules({ data_type: 'DATE', validation_rules: { min: '2026-03-21', max: '2026-12-31' } }), 'از ۱ فروردین ۱۴۰۵ · تا ۱۰ دی ۱۴۰۵');
  assert.match(describeRules({ data_type: 'DATETIME', validation_rules: { max: '2026-11-10T10:39:00Z' } }), /^تا ۱۴۰۵\/۰۸\/(۱۹|۲۰)، /);
  assert.equal(describeRules({ data_type: 'MULTI_SELECT', validation_rules: { min_items: 1, max_items: 3 } }), 'حداقل ۱ گزینه · حداکثر ۳ گزینه');
});

test('reads the option editor', () => {
  assert.deepEqual(buildOptions([{ value: ' pallet ', label: ' پالت ' }, { value: '', label: '' }, { value: 'box', label: 'کارتن' }]), {
    options: [
      { value: 'pallet', label: 'پالت' },
      { value: 'box', label: 'کارتن' },
    ],
  });
  assert.match(buildOptions([]).error, /دست‌کم یک گزینه/);
  assert.match(buildOptions([{ value: '', label: '  ' }]).error, /دست‌کم یک گزینه/);
  assert.match(buildOptions([{ value: 'a', label: '' }]).error, /هم مقدار و هم برچسب/);
  assert.match(buildOptions([{ value: '', label: 'الف' }]).error, /هم مقدار و هم برچسب/);
  assert.match(buildOptions([{ value: 'a', label: 'الف' }, { value: 'a', label: 'ب' }]).error, /تکراری/);
});
