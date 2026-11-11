/**
 * The customer portal: a visitor without an account looks a shipment up by its tracking
 * code and may read only what the company has released to customers.
 */

import assert from 'node:assert/strict';

import { PDF_BYTES, TEXT_BYTES } from './support/fixtures.mjs';
import { PHONE, fa, useApp } from './support/ui.mjs';

const GRANT_KEY = 'armin-transport.customer-access.v1';
const DESCRIPTION = 'پالت لوازم خانگی - مقصد شیراز';

/** The demo shipment used by these scenarios, with one released and one internal document. */
const fixture = {};

const app = useApp({
  async prepare({ api }) {
    const token = await api.login('armin.operator');
    const shipment = (await api.list('/shipments', token)).find((item) => item.description === DESCRIPTION);
    assert.ok(shipment, 'the demo data contains the shipment');
    await api.upload(shipment.id, token, [{ name: 'waybill.pdf', content: PDF_BYTES, type: 'application/pdf' }], { customerVisible: true });
    await api.upload(shipment.id, token, [{ name: 'internal-note.txt', content: TEXT_BYTES, type: 'text/plain' }], { customerVisible: false });
    Object.assign(fixture, { token, id: shipment.id, code: shipment.tracking_code });
  },
});

async function lookUp(ui, code) {
  await ui.fill('کد رهگیری', code);
  await ui.click('رهگیری');
}

app.scenario('a customer finds a shipment by its tracking code and sees only what was released', async (ui) => {
  await ui.open();
  await ui.waitForHash('#/track');

  // Typed the way people copy codes from paper: lower case, Persian digits, stray spaces.
  await lookUp(ui, `  ${fa(fixture.code.toLowerCase()).replaceAll('-', ' - ')} `);
  await ui.waitForText('waybill.pdf');

  const details = await ui.definitions();
  assert.equal(details['شرکت حمل‌ونقل'], 'حمل‌ونقل ');
  assert.equal(details['تعداد سندها'], fa(1), 'only the released document is counted');
  assert.equal(details['نام کالا'], 'پالت لوازم خانگی');
  assert.equal(details['وزن (کیلوگرم)'], '۱٬۲۵۰٫۵');
  assert.equal(details['تاریخ تحویل برنامه‌ریزی‌شده'], '۱۰ آذر ۱۴۰۵', '2026-12-01 in the Jalali calendar');

  // Internal fields, the internal description and the internal document stay hidden.
  for (const hidden of ['تعداد بسته', 'شکستنی', 'نوع بسته‌بندی', 'خدمات جانبی', 'توضیحات']) {
    assert.ok(!(hidden in details), `"${hidden}" must not be shown to customers`);
  }
  const text = await ui.text();
  assert.ok(text.includes(fixture.code), 'the normalised tracking code is displayed');
  assert.ok(text.includes('waybill.pdf'));
  assert.ok(!text.includes('internal-note.txt'), 'internal documents are not listed');
  assert.ok(!text.includes('مقصد شیراز'), 'the internal description is not shown');

  // The access token lives in this tab's session storage and never appears in the address.
  const grant = JSON.parse(await ui.sessionStorage(GRANT_KEY));
  assert.match(grant.token, /^[\w-]{20,}$/);
  assert.equal(await ui.hash(), '#/track');
  assert.ok(!ui.page.url().includes(grant.token));
  assert.equal(await ui.localStorage(GRANT_KEY), null, 'the token is not kept after the tab is closed');

  const file = await ui.download(() => ui.click('دریافت'));
  assert.equal(file.name, 'waybill.pdf');
  assert.deepEqual(file.content, PDF_BYTES);

  // A reload keeps the visitor on the shipment for as long as the session lasts.
  await ui.reload();
  await ui.waitForText('waybill.pdf');
  assert.equal(ui.requests('/customer/lookup').length, 1, 'the tracking code is not sent again');
  await ui.assertLayout('shipment in the customer portal');
  await ui.screenshot('portal-shipment');

  // Ending the visit revokes the token on the server as well.
  await ui.click('پایان و جست‌وجوی کد دیگر');
  await ui.waitForText('کد رهگیری‌ای را که هنگام تحویل بار دریافت کرده‌اید');
  assert.equal(await ui.sessionStorage(GRANT_KEY), null);
  const afterwards = await fetch(`${app.apiUrl}/customer/access/${grant.token}/shipment`);
  assert.equal(afterwards.status, 401);
});

app.scenario('a wrong tracking code is refused with a clear message and reveals nothing', async (ui) => {
  await ui.open('#/track');

  await ui.click('رهگیری');
  await ui.waitForText('کد رهگیری را وارد کنید.');
  assert.deepEqual(ui.requests('/api/'), [], 'an empty code is not sent to the server');

  ui.expectHttp(404, '/customer/lookup');
  await lookUp(ui, 'ZZZZ-0000-ZZZZ-0000');
  await ui.waitForText('محموله‌ای با این کد رهگیری یافت نشد. کد را بررسی کنید و دوباره تلاش کنید.');
  assert.equal(await ui.sessionStorage(GRANT_KEY), null);
  assert.equal(await ui.value('کد رهگیری'), 'ZZZZ-0000-ZZZZ-0000', 'the code stays in the box for correction');

  // The form keeps working after a failure.
  await lookUp(ui, fixture.code);
  await ui.waitForText('waybill.pdf');
});

app.scenario('when the company revokes customer access the visitor is asked for the code again', async (ui) => {
  await ui.open('#/track');
  await lookUp(ui, fixture.code);
  await ui.waitForText('waybill.pdf');

  await app.api.call('POST', `/shipments/${fixture.id}/customer-sessions/revoke`, { token: fixture.token });

  ui.expectHttp(401, '/customer/access/');
  await ui.click('دریافت');
  await ui.waitForText('نشست مشاهدهٔ محموله به پایان رسیده است. برای ادامه، کد رهگیری را دوباره وارد کنید.');
  assert.equal(await ui.sessionStorage(GRANT_KEY), null);
  assert.ok(!(await ui.hasText('waybill.pdf')), 'nothing about the shipment is left on the page');

  // The same happens when the page is opened with a token that no longer works.
  await lookUp(ui, fixture.code);
  await ui.waitForText('waybill.pdf');
  await app.api.call('POST', `/shipments/${fixture.id}/customer-sessions/revoke`, { token: fixture.token });
  await ui.reload();
  await ui.waitForText('نشست مشاهدهٔ محموله به پایان رسیده است.');
});

app.scenario(
  'the portal is usable on a phone',
  async (ui) => {
    await ui.open('#/track');
    await lookUp(ui, fixture.code);
    await ui.waitForText('waybill.pdf');
    await ui.assertLayout('customer portal on a phone');
    await ui.screenshot('phone-portal-shipment');
  },
  { viewport: PHONE },
);
