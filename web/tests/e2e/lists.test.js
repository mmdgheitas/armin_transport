/** Long lists: pages, filters and sorting, all of them kept in the address. */

import assert from 'node:assert/strict';

import { eventually, fa, signIn, useApp } from './support/ui.mjs';

const SHIPMENT_LIST = 'فهرست محموله‌ها';
const BULK = 45;
const MANUAL = 'بار با کد دستی';
const ARCHIVED = 'مواد غذایی بسته‌بندی‌شده';
const SEEDED = ['پالت لوازم خانگی - مقصد شیراز', 'قطعات یدکی خودرو - مقصد تبریز', ARCHIVED];

const numbered = (index) => `بار آزمایشی ${String(index).padStart(2, '0')}`;
/** `numbered(from)` … `numbered(to)`, counting down when `from` is the larger one. */
const run = (from, to) => Array.from({ length: Math.abs(from - to) + 1 }, (_, step) => numbered(from > to ? from - step : from + step));

/**
 * The first demo company («حمل‌ونقل», ARMIN) gets 49 shipments: the three of the demo data (one of them archived here), then
 * `numbered(1)` … `numbered(45)` and last, registered by the administrator, one with a code set by hand.
 */
const app = useApp({
  async prepare({ api }) {
    const operator = await api.login('armin.operator');
    const archived = (await api.list('/shipments', operator)).find((item) => item.description === ARCHIVED);
    await api.call('POST', `/shipments/${archived.id}/archive`, { token: operator });
    for (let index = 1; index <= BULK; index += 1) {
      await api.call('POST', '/shipments', { token: operator, json: { description: numbered(index), product_values: { product_name: `کالای ${index}` } } });
    }
    const admin = await api.login('admin');
    const company = (await api.list('/companies', admin)).find((item) => item.company_code === 'ARMIN');
    await api.call('POST', '/shipments', {
      token: admin,
      json: { company_id: company.id, tracking_code: 'LIST-1405-M1', description: MANUAL, product_values: { product_name: 'کالای امانی' } },
    });
  },
});

async function openList(ui, hash = '#/shipments') {
  await ui.open(hash);
  await signIn(ui, 'armin.operator', app.password, { landing: hash });
}

/** The «توضیحات» column of the list, top to bottom. */
async function descriptions(ui) {
  const { headers, rows } = await ui.table(SHIPMENT_LIST);
  const column = headers.indexOf('توضیحات');
  return rows.map((row) => row[column]);
}

/** Waits until the list shows exactly these descriptions, in this order. */
async function shows(ui, expected) {
  await eventually(
    async () => JSON.stringify(await descriptions(ui)) === JSON.stringify(expected),
    async () => `expected the list to show ${JSON.stringify(expected)}, but it shows ${JSON.stringify(await descriptions(ui))}`,
  );
}

/** Waits until the address is the list with exactly the parameters of `expected` (in any order). */
async function addressHas(ui, expected) {
  const canonical = (entries) => JSON.stringify([...entries].sort(([a], [b]) => a.localeCompare(b)));
  const wanted = canonical(Object.entries(expected));
  await eventually(
    async () => {
      const [path, query = ''] = (await ui.hash()).split('?');
      return path === '#/shipments' && canonical(new URLSearchParams(query)) === wanted;
    },
    async () => `expected the address to carry ${JSON.stringify(expected)}, but it is ${decodeURIComponent(await ui.hash())}`,
  );
  await ui.settled();
}

app.scenario('a long list is split into pages and the page is part of the address', async (ui) => {
  await openList(ui);
  await shows(ui, [MANUAL, ...run(45, 27)]);
  await ui.waitForText(`${fa(49)} مورد · صفحهٔ ${fa(1)} از ${fa(3)}`);
  assert.equal(await ui.isEnabled('قبلی'), false);
  assert.equal(await ui.isEnabled('بعدی'), true);

  await ui.click('بعدی');
  await addressHas(ui, { page: '2' });
  await shows(ui, run(26, 7));
  await ui.waitForText(`صفحهٔ ${fa(2)} از ${fa(3)}`);
  assert.equal(await ui.isEnabled('قبلی'), true);

  await ui.click('بعدی');
  await addressHas(ui, { page: '3' });
  await eventually(async () => (await descriptions(ui)).length === 9, 'the last page holds the remaining nine shipments');
  const last = await descriptions(ui);
  assert.deepEqual(last.slice(0, 6), run(6, 1));
  assert.deepEqual(last.slice(6).sort(), [...SEEDED].sort());
  assert.equal(await ui.isEnabled('بعدی'), false);

  // The browser's own Back button and a reload stay on the right page.
  await ui.back();
  await addressHas(ui, { page: '2' });
  await shows(ui, run(26, 7));
  await ui.reload();
  await shows(ui, run(26, 7));

  await ui.click('قبلی');
  await addressHas(ui, { page: '1' });
  await shows(ui, [MANUAL, ...run(45, 27)]);

  // An address beyond the end (an old bookmark) is corrected to the last page; the wrong address leaves no trace in the history.
  await ui.go('#/shipments?page=2');
  await shows(ui, run(26, 7));
  await ui.go('#/shipments?page=99');
  await addressHas(ui, { page: '3' });
  await eventually(async () => (await descriptions(ui)).length === 9, 'the last page is shown instead of an empty one');
  await ui.back();
  await addressHas(ui, { page: '2' });
  await shows(ui, run(26, 7));

  // A filter applies to the whole list, so it starts again at the first page …
  await ui.fill('جست‌وجو', 'بار آزمایشی');
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { q: 'بار آزمایشی' });
  await shows(ui, run(45, 26));
  await ui.waitForText(`${fa(45)} مورد · صفحهٔ ${fa(1)} از ${fa(3)}`);

  // … and paging keeps the filter.
  await ui.click('بعدی');
  await addressHas(ui, { q: 'بار آزمایشی', page: '2' });
  await shows(ui, run(25, 6));
  assert.equal(await ui.value('جست‌وجو'), 'بار آزمایشی');

  // A result that fits one page shows no page controls.
  await ui.fill('جست‌وجو', 'بار آزمایشی 1');
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { q: 'بار آزمایشی 1' });
  await shows(ui, run(19, 10));
  await ui.waitForText(`${fa(10)} مورد`);
  assert.ok(!(await ui.hasText('صفحهٔ')));
  assert.ok(!(await ui.has('بعدی')));
});

app.scenario('filters narrow the list, are kept in the address and can be removed', async (ui) => {
  await openList(ui);
  await shows(ui, [MANUAL, ...run(45, 27)]);
  assert.ok(await ui.has('فیلترها'));
  assert.ok(!(await ui.has('حذف فیلترها', { role: 'link' })));

  await ui.select('وضعیت', 'بایگانی‌شده');
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { status: 'ARCHIVED' });
  await shows(ui, [ARCHIVED]);
  assert.equal((await ui.row(ARCHIVED, SHIPMENT_LIST))['وضعیت'], 'بایگانی‌شده');
  assert.ok(await ui.has('فیلترها (فعال)'));

  // Filters combine: nothing is both archived and coded by hand.
  await ui.select('نوع کد رهگیری', 'دستی');
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { status: 'ARCHIVED', tracking_code_type: 'MANUAL' });
  await ui.waitForText('محموله‌ای با این مشخصات پیدا نشد.');
  await ui.waitForText('فیلترها را تغییر دهید یا حذف کنید.');

  await ui.select('وضعیت', 'همه');
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { tracking_code_type: 'MANUAL' });
  await shows(ui, [MANUAL]);
  const manual = await ui.row(MANUAL, SHIPMENT_LIST);
  assert.equal(manual['کد رهگیری'], 'LIST-1405-M1');
  assert.equal(manual['نوع کد'], 'دستی');
  assert.equal(manual['ثبت‌کننده'], 'مدیر سامانه');

  await ui.click('حذف فیلترها', { role: 'link' });
  assert.equal(await ui.hash(), '#/shipments');
  await shows(ui, [MANUAL, ...run(45, 27)]);
  assert.equal(await ui.value('نوع کد رهگیری'), '');

  // A code is found however it is typed: lower case, Persian digits.
  await ui.fill('جست‌وجو', 'list-۱۴۰۵');
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { q: 'list-۱۴۰۵' });
  await shows(ui, [MANUAL]);

  // Sorting is not a filter: oldest first shows the demo shipments on top.
  await ui.fill('جست‌وجو', '');
  await ui.select('ترتیب', 'قدیمی‌ترین');
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { sort: 'created_at' });
  await eventually(async () => (await descriptions(ui))[3] === numbered(1), 'the oldest shipments come first');
  const oldest = await descriptions(ui);
  assert.deepEqual(oldest.slice(0, 3).sort(), [...SEEDED].sort());
  assert.deepEqual(oldest.slice(3), run(1, 17));
  assert.ok(await ui.has('فیلترها'), 'sorting alone does not mark the filters as active');

  // Dates are entered in the Jalali calendar and travel as Gregorian dates.
  await ui.fillDate('ثبت از تاریخ', { day: '۱', month: 'فروردین', year: '۱۴۹۰' });
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { created_from: '2111-03-21', sort: 'created_at' });
  await ui.waitForText('محموله‌ای با این مشخصات پیدا نشد.');
  await ui.click('حذف فیلترها', { role: 'link' });
  await shows(ui, [MANUAL, ...run(45, 27)]);

  await ui.fillDate('ثبت تا تاریخ', { day: '۲۹', month: 'اسفند', year: '۱۳۹۹' });
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { created_to: '2021-03-19' });
  await ui.waitForText('محموله‌ای با این مشخصات پیدا نشد.');
  await ui.click('حذف فیلترها', { role: 'link' });

  await ui.fillDate('ثبت از تاریخ', { day: '۱', month: 'فروردین', year: '۱۴۰۰' });
  await ui.click('اعمال فیلتر');
  await addressHas(ui, { created_from: '2021-03-21' });
  await ui.waitForText(`${fa(49)} مورد`);
});

app.scenario('a bookmarked address restores the filters into the form', async (ui) => {
  const bookmark = `#/shipments?${new URLSearchParams({ q: 'بار آزمایشی 4', status: 'ACTIVE', sort: 'created_at', created_from: '2021-03-21' })}`;
  await openList(ui, bookmark);
  await shows(ui, run(40, 45));
  assert.equal(await ui.value('جست‌وجو'), 'بار آزمایشی 4');
  assert.equal(await ui.value('وضعیت'), 'ACTIVE');
  assert.equal(await ui.value('ترتیب'), 'created_at');
  assert.equal(await ui.value('ثبت از تاریخ: روز'), '۱');
  assert.equal(await ui.value('ثبت از تاریخ: ماه'), '1');
  assert.equal(await ui.value('ثبت از تاریخ: سال'), '۱۴۰۰');
  assert.ok(await ui.has('فیلترها (فعال)'));

  // Opening a shipment and coming back returns to the same filtered list.
  const code = (await ui.row(numbered(42), SHIPMENT_LIST))['کد رهگیری'];
  await ui.click(code, { role: 'link' });
  await ui.waitForHash(/^#\/shipments\/[0-9a-f-]{36}$/);
  await ui.waitForText(numbered(42));
  assert.ok(await ui.hasText(code));
  await ui.back();
  await shows(ui, run(40, 45));
  assert.equal(await ui.value('جست‌وجو'), 'بار آزمایشی 4');

  // Unknown or broken values in an address are ignored rather than breaking the page.
  await ui.go('#/shipments?page=abc&q=%D8%A8%D8%A7%D8%B1+%D8%A2%D8%B2%D9%85%D8%A7%DB%8C%D8%B4%DB%8C+45&colour=blue');
  await shows(ui, [numbered(45)]);
});
