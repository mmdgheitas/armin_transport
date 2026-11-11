/** The daily work of a company employee: registering shipments, documents, corrections and archiving. */

import assert from 'node:assert/strict';

import { PDF_BYTES, PNG_BYTES, useFiles } from './support/fixtures.mjs';
import { eventually, fa, signIn, useApp } from './support/ui.mjs';

const app = useApp();
const file = useFiles();

const SHIPMENT_LIST = 'فهرست محموله‌ها';
const DOCUMENT_LIST = 'سندهای محموله';
const HISTORY = 'تاریخچهٔ کد رهگیری';

const writes = (ui, urlPart) => ui.requests(urlPart).filter((request) => request.method !== 'GET');

/** Registers a shipment of «حمل‌ونقل » through the API. */
async function registerShipment(description) {
  const token = await app.api.login('armin.operator');
  const shipment = await app.api.call('POST', '/shipments', { token, json: { description, product_values: { product_name: description } } });
  return { token, id: shipment.id, code: shipment.tracking_code };
}

/** What a customer gets for `code` right now: `{ status }` on refusal, else the shipment and its document names. */
async function customerView(code) {
  const lookup = await fetch(`${app.apiUrl}/customer/lookup`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ tracking_code: code }),
  });
  if (!lookup.ok) return { status: lookup.status };
  const grant = (await lookup.json()).data.access_token;
  const shipment = await app.api.call('GET', `/customer/access/${grant}/shipment`);
  const documents = await app.api.call('GET', `/customer/access/${grant}/documents`);
  return { status: 200, shipment, documents: documents.items.map((item) => item.name).sort() };
}

async function signInAndOpen(ui, hash) {
  await ui.open(hash);
  await signIn(ui, 'armin.operator', app.password, { landing: hash });
}

app.scenario('an employee registers a shipment with its goods details', async (ui) => {
  await ui.open('#/login');
  await signIn(ui, 'armin.operator', app.password);
  await ui.click('ثبت محمولهٔ جدید', { role: 'link' });
  await ui.waitForHash('#/shipments/new');
  await ui.waitForText('کد رهگیری پس از ثبت به‌صورت خودکار، یکتا و غیرقابل‌حدس تولید می‌شود.');
  assert.ok(!(await ui.has('شرکت', { role: 'field' })), 'an employee registers shipments for the own company only');
  assert.ok(!(await ui.has('ورود دستی', { role: 'radio' })), 'manual codes are switched off for employees');
  await ui.assertLayout('new shipment');

  // Problems that the browser can see are reported without bothering the server.
  await ui.fill('تعداد بسته', 'دوازده');
  await ui.fillDate('تاریخ تحویل برنامه‌ریزی‌شده', { day: '۳۱', month: 'اسفند', year: '۱۴۰۵' });
  await ui.click('ثبت محموله');
  await ui.waitForError('نام کالا', 'وارد کردن این فیلد الزامی است.');
  await ui.waitForError('تعداد بسته', 'یک عدد صحیح معتبر وارد کنید.');
  await ui.waitForError('تاریخ تحویل برنامه‌ریزی‌شده', 'تاریخ واردشده کامل یا معتبر نیست.');
  assert.deepEqual(writes(ui, '/api/v1/shipments'), []);

  // The rules of each field are enforced by the server and shown under that field.
  ui.expectHttp(422, '/api/v1/shipments');
  await ui.fill('توضیحات', 'دستگاه برش لیزری - مقصد اصفهان');
  await ui.fill('نام کالا', 'دستگاه برش لیزری');
  await ui.fill('وزن (کیلوگرم)', '۸۵۰٫۲۵');
  await ui.fill('تعداد بسته', '۰');
  await ui.fillDate('تاریخ تحویل برنامه‌ریزی‌شده', { day: '۱۵', month: 'دی', year: '۱۴۰۵' });
  await ui.select('شکستنی', 'بله');
  await ui.select('نوع بسته‌بندی', 'کارتن');
  await ui.setChecked('بیمه', true);
  await ui.setChecked('ترخیص گمرکی', true);
  await ui.click('ثبت محموله');
  await ui.waitForError('تعداد بسته', 'مقدار باید دست‌کم ۱ باشد.');
  assert.equal(await ui.errorOf('نام کالا'), '');
  assert.equal(await ui.value('نام کالا'), 'دستگاه برش لیزری', 'what was typed is kept after a refusal');
  assert.equal(await ui.isChecked('ترخیص گمرکی'), true);

  await ui.fill('تعداد بسته', '۱۲');
  await ui.click('ثبت محموله');
  await ui.waitForToast('محموله با موفقیت ثبت شد.');
  await ui.waitForHash(/^#\/shipments\/[0-9a-f-]{36}$/);
  await ui.waitForText('مقادیر ثبت‌شده برای این محموله');

  const shown = await ui.definitions();
  assert.equal(shown['شرکت'], 'حمل‌ونقل ');
  assert.equal(shown['ثبت‌کننده'], 'سارا محمدی');
  assert.equal(shown['تعداد سندها'], '۰');
  assert.equal(shown['توضیحات'], 'دستگاه برش لیزری - مقصد اصفهان');
  assert.equal(shown['نام کالا'], 'دستگاه برش لیزری');
  assert.equal(shown['وزن (کیلوگرم)'], '۸۵۰٫۲۵');
  assert.equal(shown['تعداد بسته'], '۱۲');
  assert.equal(shown['تاریخ تحویل برنامه‌ریزی‌شده'], '۱۵ دی ۱۴۰۵');
  assert.equal(shown['شکستنی'], 'بله');
  assert.equal(shown['نوع بسته‌بندی'], 'کارتن');
  assert.equal(shown['خدمات جانبی'], 'بیمه، ترخیص گمرکی');
  assert.ok(await ui.hasText('کد خودکار'));
  await ui.assertLayout('shipment details');
  await ui.screenshot('shipment-detail');

  // What the server stored: plain numbers and a Gregorian date.
  const id = (await ui.hash()).split('/').pop();
  const token = await app.api.login('armin.operator');
  const stored = await app.api.call('GET', `/shipments/${id}/product-values`, { token });
  const values = Object.fromEntries(stored.items.map((item) => [item.field.field_key, item.value]));
  assert.equal(values.weight_kg, '850.25');
  assert.equal(values.package_count, 12);
  assert.equal(values.delivery_date, '2027-01-05');
  assert.equal(values.is_fragile, true);

  // The customer can use the code at once and sees only the fields that were released.
  const shipment = await app.api.call('GET', `/shipments/${id}`, { token });
  const customer = await customerView(shipment.tracking_code);
  assert.deepEqual(
    customer.shipment.product_details.map((detail) => detail.label),
    ['نام کالا', 'وزن (کیلوگرم)', 'تاریخ تحویل برنامه‌ریزی‌شده'],
  );
  assert.equal(customer.shipment.description, null, 'the description is internal by default');

  await ui.click('بازگشت به فهرست', { role: 'link' });
  const row = await ui.waitForRow('دستگاه برش لیزری', SHIPMENT_LIST);
  assert.equal(row['کد رهگیری'], shipment.tracking_code);
  assert.equal(row['ثبت‌کننده'], 'سارا محمدی');
  assert.equal(row['نوع کد'], 'خودکار');
  assert.equal(row['وضعیت'], 'فعال');
  assert.equal((await ui.table(SHIPMENT_LIST)).rows[0][1], 'دستگاه برش لیزری - مقصد اصفهان', 'the newest shipment is listed first');
});

app.scenario('an employee uploads documents, decides what the customer sees and downloads a file', async (ui) => {
  const shipment = await registerShipment('محمولهٔ آزمون سندها');
  await signInAndOpen(ui, `#/shipments/${shipment.id}?tab=documents`);
  await ui.waitForText('هنوز سندی برای این محموله بارگذاری نشده است.');
  assert.equal(await ui.isEnabled('بارگذاری'), false);

  // Files that can never be accepted are refused before anything is sent.
  await ui.chooseFiles(await file('setup.exe', 'MZ not really a program'), await file('empty.pdf', ''));
  await ui.waitForText('قالب این فایل مجاز نیست.');
  await ui.waitForText('فایل خالی است.');
  assert.equal(await ui.isEnabled(`بارگذاری ${fa(2)} فایل`), false);
  await ui.click('حذف setup.exe از فهرست');
  await ui.click('حذف empty.pdf از فهرست');
  assert.deepEqual(writes(ui, '/documents'), []);

  // The server looks inside the files; one bad file stops the whole batch.
  ui.expectHttp(422, `/shipments/${shipment.id}/documents`);
  await ui.chooseFiles(await file('invoice.pdf', PDF_BYTES), await file('fake.pdf', 'plain text that pretends to be a PDF'));
  await ui.click(`بارگذاری ${fa(2)} فایل`);
  await ui.waitForText('محتوای فایل با پسوند آن همخوانی ندارد');
  await ui.waitForText('هیچ فایلی بارگذاری نشد.');
  assert.deepEqual(await app.api.list(`/shipments/${shipment.id}/documents`, shipment.token), [], 'nothing is stored from a refused batch');

  await ui.click('حذف fake.pdf از فهرست');
  await ui.chooseFiles(await file('photo.png', PNG_BYTES));
  assert.equal(await ui.isChecked('مشتری بتواند این سندها را با کد رهگیری ببیند'), true);
  await ui.click(`بارگذاری ${fa(2)} فایل`);
  await ui.waitForToast('سندها با موفقیت بارگذاری شدند.');
  const invoice = await ui.waitForRow('invoice.pdf', DOCUMENT_LIST);
  assert.equal(invoice['بارگذاری‌کننده'], 'سارا محمدی');
  await ui.waitForRow('photo.png', DOCUMENT_LIST);
  await ui.waitForText(`سندها (${fa(2)})`);
  assert.equal(await ui.hash(), `#/shipments/${shipment.id}?tab=documents`, 'the documents tab stays open after the upload');
  assert.equal((await ui.definitions())['تعداد سندها'], fa(2));
  assert.deepEqual((await customerView(shipment.code)).documents, ['invoice.pdf', 'photo.png']);
  await ui.assertLayout('shipment documents');
  await ui.screenshot('shipment-documents');

  // Hiding a document takes effect for the customer immediately.
  await ui.setChecked('نمایش photo.png به مشتری', false);
  await ui.waitForToast('وضعیت نمایش سند به‌روزرسانی شد.');
  assert.deepEqual((await customerView(shipment.code)).documents, ['invoice.pdf']);
  await ui.reload();
  await ui.waitForRow('photo.png', DOCUMENT_LIST);
  assert.equal(await ui.isChecked('نمایش photo.png به مشتری'), false);
  assert.equal(await ui.isChecked('نمایش invoice.pdf به مشتری'), true);

  const saved = await ui.download(() => ui.click('دریافت invoice.pdf'));
  assert.equal(saved.name, 'invoice.pdf');
  assert.deepEqual(saved.content, PDF_BYTES);

  assert.ok(!(await ui.has('حذف invoice.pdf')), 'employees may not delete documents unless the setting allows it');
});

app.scenario('an employee corrects the details and replaces the tracking code', async (ui) => {
  const shipment = await registerShipment('محمولهٔ آزمون ویرایش');
  await signInAndOpen(ui, `#/shipments/${shipment.id}`);
  await ui.waitForText('مقادیر ثبت‌شده برای این محموله');

  await ui.click('ویرایش توضیحات');
  assert.equal(await ui.value('توضیحات'), 'محمولهٔ آزمون ویرایش');
  await ui.fill('توضیحات', 'قطعات صنعتی - تحویل در انبار مرکزی');
  await ui.click('ذخیره');
  await ui.waitForToast('محموله به‌روزرسانی شد.');
  await ui.waitForText('قطعات صنعتی - تحویل در انبار مرکزی');

  // The form opens with the stored values; a refused value is explained under its field.
  await ui.click('ویرایش مشخصات');
  assert.equal(await ui.value('نام کالا'), 'محمولهٔ آزمون ویرایش');
  ui.expectHttp(422, '/product-values');
  await ui.fill('نام کالا', 'قطعات صنعتی');
  await ui.fill('وزن (کیلوگرم)', '12.34567');
  await ui.click('ذخیرهٔ مشخصات');
  await ui.waitForError('وزن (کیلوگرم)', 'تعداد رقم‌های اعشار نباید بیشتر از ۳ باشد.');
  await ui.fill('وزن (کیلوگرم)', '12.5');
  await ui.setChecked('بارگیری', true);
  await ui.click('ذخیرهٔ مشخصات');
  await ui.waitForToast('مشخصات کالا ذخیره شد.');
  await ui.waitForText('مقادیر ثبت‌شده برای این محموله');
  const shown = await ui.definitions();
  assert.equal(shown['نام کالا'], 'قطعات صنعتی');
  assert.equal(shown['وزن (کیلوگرم)'], '۱۲٫۵');
  assert.equal(shown['خدمات جانبی'], 'بارگیری');
  assert.equal(shown['تعداد بسته'], '—');

  // «انصراف» leaves the stored values alone.
  await ui.click('ویرایش مشخصات');
  await ui.fill('نام کالا', 'نباید ذخیره شود');
  await ui.click('انصراف');
  assert.equal((await ui.definitions())['نام کالا'], 'قطعات صنعتی');

  // Employees may ask for a new generated code but cannot type one.
  await ui.click('تغییر کد رهگیری');
  await ui.waitForText(shipment.code);
  assert.ok(!(await ui.has('کد رهگیری جدید', { role: 'field' })));
  await ui.click('تولید کد جدید');
  await ui.waitForToast('کد رهگیری تغییر کرد.');
  const current = (await app.api.call('GET', `/shipments/${shipment.id}`, { token: shipment.token })).tracking_code;
  assert.notEqual(current, shipment.code);
  await ui.waitForText(current);

  await ui.click(HISTORY, { role: 'tab' });
  await ui.waitForHash(`#/shipments/${shipment.id}?tab=history`);
  const change = await ui.waitForRow(current, HISTORY);
  assert.equal(change['کد قبلی'], shipment.code);
  assert.equal(change['کد جدید'], current);
  assert.equal(change['تغییردهنده'], 'سارا محمدی');
  assert.equal((await ui.table(HISTORY)).rows.length, 2, 'the first code and the change are both on record');
  assert.ok(await ui.hasText('— (ثبت اولیه)'));

  // The open tab is part of the address, so a reload (or a shared link) shows the same view.
  await ui.reload();
  await ui.waitForRow(current, HISTORY);

  assert.equal((await customerView(shipment.code)).status, 404, 'the replaced code stops working');
  assert.equal((await customerView(current)).status, 200);
});

app.scenario('an archived shipment can only be viewed', async (ui) => {
  const shipment = await registerShipment('محمولهٔ آزمون بایگانی');
  await app.api.upload(shipment.id, shipment.token, [{ name: 'receipt.pdf', content: PDF_BYTES, type: 'application/pdf' }]);
  await signInAndOpen(ui, `#/shipments/${shipment.id}`);
  await ui.waitForText('مقادیر ثبت‌شده برای این محموله');

  // Archiving asks first; declining changes nothing.
  await ui.click('بایگانی');
  await ui.waitForText('محمولهٔ بایگانی‌شده فقط قابل مشاهده است');
  await ui.click('انصراف');
  assert.deepEqual(writes(ui, '/archive'), []);

  await ui.click('بایگانی');
  await ui.click('بایگانی شود');
  await ui.waitForToast('محموله بایگانی شد.');
  await ui.waitForText('این محموله بایگانی شده است و فقط می‌توان آن را مشاهده و سندهایش را دریافت کرد.');
  await eventually(async () => (await ui.definitions())['نام کالا'] === 'محمولهٔ آزمون بایگانی', 'the goods details are still shown after archiving');

  for (const action of ['ویرایش توضیحات', 'تغییر کد رهگیری', 'بایگانی', 'خروج از بایگانی', 'ویرایش مشخصات']) {
    assert.ok(!(await ui.has(action)), `«${action}» must not be offered for an archived shipment`);
  }

  await ui.click('سندها', { role: 'tab', exact: false });
  const row = await ui.waitForRow('receipt.pdf', DOCUMENT_LIST);
  assert.equal(row['نمایش به مشتری'], 'قابل مشاهده');
  assert.ok(!(await ui.has('فایل‌ها را اینجا رها کنید', { exact: false })), 'nothing can be added to an archived shipment');
  assert.ok(!(await ui.has('نمایش receipt.pdf به مشتری', { role: 'checkbox' })));
  const saved = await ui.download(() => ui.click('دریافت receipt.pdf'));
  assert.deepEqual(saved.content, PDF_BYTES);
  await ui.screenshot('shipment-archived');

  assert.equal((await customerView(shipment.code)).status, 404, 'customers cannot open archived shipments by default');

  await ui.go('#/shipments?status=ARCHIVED');
  const listed = await ui.waitForRow('محمولهٔ آزمون بایگانی', SHIPMENT_LIST);
  assert.equal(listed['وضعیت'], 'بایگانی‌شده');
  assert.equal((await ui.table(SHIPMENT_LIST)).rows.length, 1);
});

app.scenario('an employee cannot reach the shipments of another company', async (ui) => {
  const foreign = (await app.api.list('/shipments', await app.api.login('pars.operator'))).find((item) => item.description === 'تجهیزات پزشکی');
  assert.ok(foreign);

  await signInAndOpen(ui, '#/shipments');
  await ui.waitForRow('مواد غذایی بسته‌بندی‌شده', SHIPMENT_LIST);
  const { headers, rows } = await ui.table(SHIPMENT_LIST);
  assert.ok(!headers.includes('شرکت'), 'the company column is for the central administrator');
  assert.ok(rows.every((row) => !row.join(' ').includes('تجهیزات پزشکی') && !row.join(' ').includes('کاشی و سرامیک')));

  await ui.fill('جست‌وجو', foreign.tracking_code);
  await ui.click('اعمال فیلتر');
  await ui.waitForText('محموله‌ای با این مشخصات پیدا نشد.');

  // Guessing the address of a foreign shipment gives the same answer as a shipment that does not exist.
  ui.expectHttp(404, `/shipments/${foreign.id}`);
  await ui.go(`#/shipments/${foreign.id}`);
  await ui.waitForText('محمولهٔ موردنظر یافت نشد.');
  assert.ok(!(await ui.hasText(foreign.tracking_code)));
  assert.ok(!(await ui.hasText('تجهیزات پزشکی')));

  ui.expectHttp(404, '/shipments/00000000-0000-4000-8000-000000000000');
  await ui.go('#/shipments/00000000-0000-4000-8000-000000000000');
  await ui.waitForText('محمولهٔ موردنظر یافت نشد.');
});
