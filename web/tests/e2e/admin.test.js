/** The central administrator: companies, employees, cross-company work and the audit log. */

import assert from 'node:assert/strict';

import { eventually, fa, signIn, useApp } from './support/ui.mjs';

const app = useApp();

const COMPANY_LIST = 'فهرست شرکت‌ها';
const USER_LIST = 'فهرست کاربران';
const SHIPMENT_LIST = 'فهرست محموله‌ها';
const AUDIT_LOG = 'گزارش رویدادها';

async function signInAsAdmin(ui, hash) {
  await ui.open(hash);
  await signIn(ui, 'admin', app.password, { landing: hash });
}

/** HTTP status and error code of a login attempt made outside the browser. */
async function loginAttempt(username, password) {
  const response = await fetch(`${app.apiUrl}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  });
  const body = await response.json();
  return { status: response.status, code: body.errors?.code ?? null, token: body.data?.access_token ?? null };
}

app.scenario('the administrator registers a company and its first employee, who can start working at once', async (ui) => {
  const password = 'Kavir-Shoroo-7391';
  await signInAsAdmin(ui, '#/companies');
  await ui.waitForRow('باربری پارس', COMPANY_LIST);
  await ui.assertLayout('companies');

  await ui.click('شرکت جدید');
  await ui.click('ایجاد شرکت');
  await ui.waitForError('نام شرکت', 'نام شرکت را وارد کنید.');
  await ui.waitForError('کد شرکت', 'کد شرکت را وارد کنید.');
  assert.deepEqual(
    ui.requests('/api/v1/companies').filter((request) => request.method === 'POST'),
    [],
  );

  // Company codes are unique whatever their letter case.
  ui.expectHttp(409, '/api/v1/companies');
  await ui.fill('نام شرکت', 'ترابر کویر');
  await ui.fill('کد شرکت', 'armin');
  await ui.click('ایجاد شرکت');
  await ui.waitForError('کد شرکت', 'این کد شرکت قبلاً استفاده شده است.');
  await ui.screenshot('company-modal-error');

  ui.expectHttp(422, '/api/v1/companies');
  await ui.fill('کد شرکت', 'kavir');
  await ui.fill('تلفن', 'داخلی ۱۲');
  await ui.click('ایجاد شرکت');
  await ui.waitForError('تلفن', 'شمارهٔ تلفن فقط می‌تواند شامل رقم، فاصله و نشانه‌های + - ( ) باشد.');

  await ui.fill('تلفن', '035-3824 5510');
  await ui.fill('نشانی', 'یزد، بلوار جمهوری، پایانهٔ بار');
  await ui.click('ایجاد شرکت');
  await ui.waitForToast('شرکت با موفقیت ایجاد شد.');
  const company = await ui.waitForRow('ترابر کویر', COMPANY_LIST);
  assert.equal(company['کد'], 'KAVIR');
  assert.equal(company['تلفن'], '035-3824 5510');
  assert.equal(company['وضعیت'], 'فعال');

  // From the company straight to its (still empty) list of employees.
  await ui.click('کارمندان ترابر کویر', { role: 'link' });
  await ui.waitForHash(/^#\/users\?company_id=[0-9a-f-]{36}$/);
  await ui.waitForText('کاربری با این مشخصات پیدا نشد.');
  const companyId = (await ui.hash()).split('company_id=')[1];

  await ui.click('کارمند جدید');
  await eventually(async () => (await ui.value('شرکت')) === companyId, 'the company of the filtered list is preselected');
  await ui.click('ایجاد کارمند');
  await ui.waitForError('نام و نام خانوادگی', 'نام را وارد کنید.');
  await ui.waitForError('نام کاربری', 'نام کاربری را وارد کنید.');
  await ui.waitForError('رمز عبور اولیه', 'رمز عبور را وارد کنید.');

  ui.expectHttp(422, '/api/v1/users');
  await ui.fill('نام و نام خانوادگی', 'نگار رستمی');
  await ui.fill('نام کاربری', 'kavir.operator');
  await ui.fill('رمز عبور اولیه', 'kootah');
  await ui.click('ایجاد کارمند');
  await ui.waitForError('رمز عبور اولیه', 'رمز عبور باید دست‌کم ۱۰ نویسه باشد.');

  await ui.fill('رمز عبور اولیه', 'kavir.operator-1405');
  await ui.click('ایجاد کارمند');
  await ui.waitForError('رمز عبور اولیه', 'رمز عبور نباید شامل نام کاربری باشد.');

  ui.expectHttp(409, '/api/v1/users');
  await ui.fill('نام کاربری', 'Armin.Operator');
  await ui.fill('رمز عبور اولیه', password);
  await ui.click('ایجاد کارمند');
  await ui.waitForError('نام کاربری', 'این نام کاربری قبلاً استفاده شده است.');

  await ui.fill('نام کاربری', 'kavir.operator');
  await ui.click('ایجاد کارمند');
  await ui.waitForToast('کارمند با موفقیت ایجاد شد.');
  const employee = await ui.waitForRow('نگار رستمی', USER_LIST);
  assert.equal(employee['نام کاربری'], 'kavir.operator');
  assert.equal(employee['نقش'], 'کارمند');
  assert.equal(employee['شرکت'], 'ترابر کویر');
  assert.equal(employee['وضعیت'], 'فعال');
  assert.equal(employee['آخرین ورود'], 'هنوز وارد نشده');
  assert.equal((await ui.table(USER_LIST)).rows.length, 1, 'the list is still filtered by the company');

  // The new employee signs in and finds an empty workplace of the own company.
  await ui.click('خروج');
  await ui.waitForHash('#/login');
  await signIn(ui, 'kavir.operator', password);
  await ui.waitForText('نگار رستمی، خوش آمدید');
  await ui.waitForText('خلاصهٔ وضعیت ترابر کویر');
  await ui.waitForText('هنوز محموله‌ای ثبت نشده است.');
});

app.scenario('switching a company off locks its employees out until it is switched on again', async (ui) => {
  assert.equal((await loginAttempt('pars.operator', app.password)).status, 200);
  await signInAsAdmin(ui, '#/companies');

  await ui.click('ویرایش باربری پارس');
  await ui.waitForText(`${fa(1)} کارمند و ${fa(2)} محموله برای این شرکت ثبت شده است.`);
  assert.equal(await ui.value('کد شرکت'), 'PARS');
  await ui.setChecked('شرکت فعال است', false);
  await ui.click('ذخیرهٔ تغییرات');
  await ui.waitForToast('اطلاعات شرکت به‌روزرسانی شد.');
  await eventually(async () => (await ui.row('باربری پارس', COMPANY_LIST))?.['وضعیت'] === 'غیرفعال', 'the company is shown as inactive');

  assert.deepEqual(await loginAttempt('pars.operator', app.password), { status: 403, code: 'company_inactive', token: null });

  // Nothing new can be registered for it, but its shipments stay available to the administrator.
  await ui.go('#/shipments/new');
  await ui.waitForText('اطلاعات محموله');
  const offered = await ui.options('شرکت');
  assert.ok(offered.includes('حمل‌ونقل آرمین (ARMIN)'));
  assert.ok(!offered.some((option) => option.includes('باربری پارس')), 'an inactive company is not offered for new shipments');
  await ui.go('#/shipments');
  await ui.waitForRow('تجهیزات پزشکی', SHIPMENT_LIST);

  // The filter finds it among the inactive companies.
  await ui.go('#/companies?is_active=false');
  await ui.waitForRow('باربری پارس', COMPANY_LIST);
  assert.equal((await ui.table(COMPANY_LIST)).rows.length, 1);
  await ui.click('ویرایش باربری پارس');
  await ui.setChecked('شرکت فعال است', true);
  await ui.click('ذخیرهٔ تغییرات');
  await ui.waitForToast('اطلاعات شرکت به‌روزرسانی شد.');
  await ui.waitForText('شرکتی با این مشخصات پیدا نشد.');

  assert.equal((await loginAttempt('pars.operator', app.password)).status, 200);
});

app.scenario('the administrator edits an employee and resets a forgotten password', async (ui) => {
  const newPassword = 'Ramz-Jadid-5521!';
  const openSession = (await loginAttempt('armin.clerk', app.password)).token;
  assert.ok(openSession);

  await signInAsAdmin(ui, '#/users');
  await ui.waitForRow('رضا کریمی', USER_LIST);
  await ui.assertLayout('users');
  assert.deepEqual(await ui.names('button', { row: 'مدیر سامانه' }), [], 'administrator accounts are not managed through the web');

  await ui.click('ویرایش رضا کریمی');
  assert.equal(await ui.value('نام کاربری'), 'armin.clerk');
  assert.ok(!(await ui.has('رمز عبور اولیه', { role: 'field' })), 'a password is never shown or edited in the profile form');
  await ui.fill('نام و نام خانوادگی', 'رضا کریمی‌نژاد');
  await ui.click('ذخیرهٔ تغییرات');
  await ui.waitForToast('اطلاعات کارمند به‌روزرسانی شد.');
  await ui.waitForRow('رضا کریمی‌نژاد', USER_LIST);

  await ui.click('بازنشانی رمز رضا کریمی‌نژاد');
  await ui.waitForText('همهٔ نشست‌های فعال «رضا کریمی‌نژاد» بسته می‌شود');
  ui.expectHttp(422, '/reset-password');
  await ui.fill('رمز عبور جدید', 'kootah');
  await ui.click('تغییر رمز عبور');
  await ui.waitForError('رمز عبور جدید', 'رمز عبور باید دست‌کم ۱۰ نویسه باشد.');
  await ui.fill('رمز عبور جدید', newPassword);
  await ui.click('تغییر رمز عبور');
  await ui.waitForToast('رمز عبور کارمند بازنشانی شد و نشست‌های قبلی او باطل شدند.');

  const stale = await fetch(`${app.apiUrl}/auth/me`, { headers: { Authorization: `Bearer ${openSession}` } });
  assert.equal(stale.status, 401, 'the session that was open before the reset is closed');
  assert.equal((await loginAttempt('armin.clerk', app.password)).status, 401);
  assert.equal((await loginAttempt('armin.clerk', newPassword)).status, 200);

  // Search and filters live in the address, so a filtered list can be bookmarked.
  await ui.fill('جست‌وجو', 'clerk');
  await ui.select('نقش', 'کارمند');
  await ui.click('اعمال فیلتر');
  await ui.waitForHash('#/users?q=clerk&role=EMPLOYEE');
  await eventually(async () => (await ui.table(USER_LIST)).rows.length === 1, 'only the matching employee is listed');
  await ui.reload();
  await ui.waitForRow('رضا کریمی‌نژاد', USER_LIST);
  assert.equal(await ui.value('جست‌وجو'), 'clerk');
  assert.equal((await ui.table(USER_LIST)).rows.length, 1);
});

app.scenario('the administrator works across companies, sets tracking codes by hand and restores archived shipments', async (ui) => {
  const token = await app.api.login('admin');
  const taken = (await app.api.list('/shipments', token)).find((item) => item.description === 'تجهیزات پزشکی').tracking_code;

  await signInAsAdmin(ui, '#/shipments');
  await ui.waitForRow('تجهیزات پزشکی', SHIPMENT_LIST);
  const all = await ui.table(SHIPMENT_LIST);
  assert.ok(all.headers.includes('شرکت'));
  const companyColumn = all.headers.indexOf('شرکت');
  assert.deepEqual([...new Set(all.rows.map((row) => row[companyColumn]))].sort(), ['باربری پارس', 'حمل‌ونقل آرمین']);
  await ui.assertLayout('shipments');

  await ui.select('شرکت', 'باربری پارس (PARS)');
  await ui.click('اعمال فیلتر');
  await ui.waitForHash(/^#\/shipments\?company_id=[0-9a-f-]{36}$/);
  await eventually(async () => {
    const { rows } = await ui.table(SHIPMENT_LIST);
    return rows.length > 0 && rows.every((row) => row[companyColumn] === 'باربری پارس');
  }, 'only the shipments of the chosen company are listed');
  await ui.click('حذف فیلترها', { role: 'link' });
  await ui.waitForHash('#/shipments');

  // A code typed by hand: checked in the browser, normalised, unique.
  await ui.click('ثبت محمولهٔ جدید', { role: 'link' });
  assert.equal(await ui.hash(), '#/shipments/new');
  await ui.select('شرکت', 'حمل‌ونقل آرمین (ARMIN)');
  await ui.fill('نام کالا', 'بار امانی');
  await ui.choose('ورود دستی');
  await ui.click('ثبت محموله');
  await ui.waitForError('کد رهگیری دستی', 'کد رهگیری را وارد کنید.');
  await ui.fill('کد رهگیری دستی', 'ab-1');
  await ui.click('ثبت محموله');
  await ui.waitForError('کد رهگیری دستی', 'کد رهگیری باید دست‌کم ۶ نویسه باشد.');
  await ui.fill('کد رهگیری دستی', 'amanat_1405');
  await ui.click('ثبت محموله');
  await ui.waitForError('کد رهگیری دستی', 'کد رهگیری فقط می‌تواند شامل حروف انگلیسی، رقم و خط تیره باشد');

  ui.expectHttp(409, '/api/v1/shipments');
  await ui.fill('کد رهگیری دستی', taken.toLowerCase());
  await ui.click('ثبت محموله');
  await ui.waitForError('کد رهگیری دستی', 'این کد رهگیری قبلاً استفاده شده است');

  await ui.fill('کد رهگیری دستی', ' amanat-۱۴۰۵-b7 ');
  await ui.click('ثبت محموله');
  await ui.waitForToast('محموله با موفقیت ثبت شد.');
  await ui.waitForHash(/^#\/shipments\/[0-9a-f-]{36}$/);
  await ui.waitForText('AMANAT-1405-B7');
  await ui.waitForText('کد دستی');
  const shipmentHash = await ui.hash();

  await ui.click('تغییر کد رهگیری');
  await ui.fill('کد رهگیری جدید', 'amanat-1405-c9');
  await ui.click('تغییر کد');
  await ui.waitForToast('کد رهگیری تغییر کرد.');
  await ui.waitForText('AMANAT-1405-C9');

  // A code that was ever used is never accepted again, not even for the same shipment.
  ui.expectHttp(409, '/tracking-code');
  await ui.click('تغییر کد رهگیری');
  await ui.fill('کد رهگیری جدید', 'AMANAT-1405-B7');
  await ui.click('تغییر کد');
  await ui.waitForError('کد رهگیری جدید', 'قابل استفادهٔ دوباره نیست');
  await ui.click('انصراف');

  // Leaving the field empty asks for a generated code.
  await ui.click('تغییر کد رهگیری');
  await ui.click('تغییر کد');
  await ui.waitForToast('کد رهگیری تغییر کرد.');
  await ui.waitForNoText('AMANAT-1405-C9');
  await ui.waitForText('کد خودکار');

  // Only the administrator can bring an archived shipment back.
  await ui.click('بایگانی');
  await ui.click('بایگانی شود');
  await ui.waitForToast('محموله بایگانی شد.');
  await ui.waitForText('این محموله بایگانی شده است');
  await ui.click('خروج از بایگانی');
  await ui.waitForToast('محموله دوباره فعال شد.');
  await ui.waitForNoText('این محموله بایگانی شده است');
  assert.ok(await ui.has('بایگانی'));
  assert.ok(await ui.has('ویرایش توضیحات'));
  assert.equal(await ui.hash(), shipmentHash);
});

/** Waits until the audit log lists events of one kind only (the list is replaced a moment after a filter is applied). */
async function listsOnlyEvent(ui, label) {
  await eventually(async () => {
    const { headers, rows } = await ui.table(AUDIT_LOG);
    const column = headers.indexOf('رویداد');
    return rows.length > 0 && rows.every((row) => row[column] === label);
  }, `the audit log lists only "${label}" events`);
}

app.scenario('the audit log shows who did what and can be filtered', async (ui) => {
  assert.equal((await loginAttempt('armin.operator', 'not-the-password')).status, 401);
  const operator = await app.api.login('armin.operator');
  const shipment = await app.api.call('POST', '/shipments', { token: operator, json: { description: 'محمولهٔ آزمون گزارش', product_values: { product_name: 'کالای آزمون' } } });

  await signInAsAdmin(ui, '#/audit-logs');
  await ui.waitForRow('ورود موفق', AUDIT_LOG);
  await ui.assertLayout('audit log');

  await ui.select('رویداد', 'ورود ناموفق');
  await ui.click('اعمال فیلتر');
  await ui.waitForHash('#/audit-logs?action=LOGIN_FAILED');
  await listsOnlyEvent(ui, 'ورود ناموفق');
  assert.equal((await ui.row('ورود ناموفق', AUDIT_LOG))['کاربر'], 'سارا محمدی');

  await ui.click('نمایش جزئیات رویداد', { index: 0 });
  await ui.waitForText('"reason": "wrong_password"');
  const entry = await ui.definitions();
  assert.equal(entry['رویداد'], 'LOGIN_FAILED');
  assert.equal(entry['کاربر'], 'سارا محمدی (armin.operator)');
  assert.equal(entry['موجودیت'], 'کاربر');
  assert.ok(!(await ui.hasText('not-the-password')), 'the attempted password is never recorded');
  await ui.screenshot('audit-details');
  await ui.click('بستن');

  // A period without events, entered as Jalali dates.
  await ui.fillDate('از تاریخ', { day: '۱', month: 'فروردین', year: '۱۴۹۰' });
  await ui.click('اعمال فیلتر');
  await ui.waitForHash('#/audit-logs?action=LOGIN_FAILED&created_from=2111-03-21');
  await ui.waitForText('رویدادی با این مشخصات پیدا نشد.');
  await ui.fillDate('از تاریخ', { day: '۳۱', month: 'مهر', year: '۱۴۰۵' });
  await ui.click('اعمال فیلتر');
  await ui.waitForError('از تاریخ', 'تاریخ واردشده کامل یا معتبر نیست.');
  await ui.click('حذف فیلترها', { role: 'link' });
  await ui.waitForHash('#/audit-logs');

  // An event about a shipment leads to that shipment.
  await ui.select('رویداد', 'ثبت محموله');
  await ui.click('اعمال فیلتر');
  await ui.waitForHash('#/audit-logs?action=SHIPMENT_CREATED');
  await listsOnlyEvent(ui, 'ثبت محموله');
  const created = await ui.row('ثبت محموله', AUDIT_LOG);
  assert.equal(created['کاربر'], 'سارا محمدی');
  assert.equal(created['موجودیت'], 'محموله');
  await ui.click('نمایش جزئیات رویداد', { index: 0 });
  await ui.waitForText(shipment.tracking_code);
  await ui.click('مشاهدهٔ محموله', { role: 'link' });
  await ui.waitForHash(`#/shipments/${shipment.id}`);
  await ui.waitForText('محمولهٔ آزمون گزارش');
  assert.ok(!(await ui.has('بستن')), 'the dialog closes when the page changes');
});
