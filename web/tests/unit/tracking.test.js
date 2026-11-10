import assert from 'node:assert/strict';
import { test } from 'node:test';

import { normalizeTrackingCode, trackingCodeProblem } from '../../src/js/core/tracking.js';

test('normalizes codes exactly like the backend', () => {
  const cases = [
    ['abcd-1234', 'ABCD-1234'],
    ['  ab cd\t12 34\n', 'ABCD1234'],
    ['۱۲۳۴-۵۶۷۸', '1234-5678'],
    ['٠١٢٣٤٥', '012345'],
    ['AB\u2013CD\u2014EF\u2212GH\u2010IJ', 'AB-CD-EF-GH-IJ'],
    ['AB\u200cCD\u200bEF\ufeff', 'ABCDEF'],
    ['ＡＢＣ１２３', 'ABC123'], // full-width forms are folded by NFKC
    ['', ''],
    [null, ''],
    [undefined, ''],
  ];
  for (const [input, expected] of cases) assert.equal(normalizeTrackingCode(input), expected, JSON.stringify(input));
});

test('reports problems in Persian and accepts valid codes', () => {
  assert.equal(trackingCodeProblem('ABCD-1234-EFGH-5678'), null);
  assert.equal(trackingCodeProblem('ABC123'), null);
  assert.match(trackingCodeProblem(''), /وارد کنید/);
  assert.match(trackingCodeProblem('ABC'), /دست‌کم ۶ نویسه/);
  assert.match(trackingCodeProblem('A'.repeat(65)), /بیشتر از ۶۴ نویسه/);
  assert.match(trackingCodeProblem('-ABCDEF'), /خط تیره/);
  assert.match(trackingCodeProblem('ABCDEF-'), /خط تیره/);
  assert.match(trackingCodeProblem('ABC_DEF'), /حروف انگلیسی/);
  assert.match(trackingCodeProblem('کدفارسی'), /حروف انگلیسی/);
});

test('honours the limits announced by the server', () => {
  const rules = { min_length: 8, max_length: 10, pattern: '^[A-Z0-9]+$' };
  assert.match(trackingCodeProblem('ABCDEFG', rules), /دست‌کم ۸ نویسه/);
  assert.match(trackingCodeProblem('ABCDEFGHIJK', rules), /بیشتر از ۱۰ نویسه/);
  assert.match(trackingCodeProblem('ABCD-EFGH', rules), /حروف انگلیسی/);
  assert.equal(trackingCodeProblem('ABCDEFGH', rules), null);
  assert.equal(trackingCodeProblem('ABCDEF', {}), null); // missing values fall back to the defaults
});
