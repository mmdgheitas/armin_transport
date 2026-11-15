/** Real SQLite/Gunicorn/browser coverage for the new management controls. */
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { startBackend, apiClient, DEMO_PASSWORD } from './support/backend.mjs';
import { launchBrowser } from './support/browser.mjs';

test('transport CRUD controls edit, delete and restore companies, staff, loads and files', { timeout: 120000 }, async () => {
  const backend = await startBackend();
  let browser;
  const filesDir = await mkdtemp(path.join(os.tmpdir(), 'transport-crud-'));
  const replacementPath = path.join(filesDir, 'replacement-ui.bin');
  await writeFile(replacementPath, 'replacement bytes');
  try {
    browser = await launchBrowser();
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    const api = apiClient(backend.apiUrl);
    const token = await api.login('admin');
    const call = (method, route, json) => api.call(method, route, { token, json });
    const company = await call('POST', '/transport/companies', { name: 'CRUD UI company' });
    const employee = await call('POST', '/transport/employees', { full_name: 'CRUD UI employee', username: 'crud-ui-employee', password: DEMO_PASSWORD, country: 'CI' });
    const shipment = await call('POST', '/transport/shipments', { company_id: company.id, tracking_code: 'CRUD UI code', countries: ['CI', 'KZ'], upload_limit: 2, truck_count: 1, border_count: 0, employee_ids: [employee.id] });
    const form = new FormData(); form.append('country', 'CI'); form.append('files', new Blob(['original']), 'ui.bin');
    const upload = await fetch(`${backend.apiUrl}/transport/shipments/${shipment.id}/files`, { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: form });
    assert.equal(upload.status, 201);
    const click = async (text) => {
      await page.waitForFunction((label) => {
        const button = [...document.querySelectorAll('dialog[open] button, body:not(:has(dialog[open])) button')].find((item) => item.textContent.trim() === label);
        if (!button || button.disabled) return false;
        button.click(); return true;
      }, {}, text);
    };
    const fill = async (label, value) => {
      await page.waitForFunction((text) => [...(document.querySelector('dialog[open]') ?? document).querySelectorAll('label')].some((item) => item.textContent.replace('*', '').trim() === text), {}, label);
      await page.evaluate((args) => {
        const scope = document.querySelector('dialog[open]') ?? document;
        const fieldLabel = [...scope.querySelectorAll('label')].find((item) => item.textContent.replace('*', '').trim() === args.label);
        const input = document.getElementById(fieldLabel.htmlFor);
        input.value = args.value; input.dispatchEvent(new Event('input', { bubbles: true }));
      }, { label, value });
    };
    const waitText = (text) => page.waitForFunction((value) => document.body.textContent.includes(value), {}, text);
    const navigate = async (hash) => { await page.goto(`${backend.baseUrl}/${hash}`); };
    await navigate('#/login');
    await fill('نام کاربری', 'admin'); await fill('رمز عبور', DEMO_PASSWORD); await click('ورود');
    await page.waitForFunction(() => location.hash === '#/dashboard');
    await navigate('#/companies'); await waitText(company.name);
    await click('ویرایش شرکت'); await fill('اسم شرکت', 'CRUD UI renamed'); await click('ثبت'); await waitText('CRUD UI renamed');
    assert.equal((await call('GET', '/transport/companies')).items.find((item) => item.id === company.id).name, 'CRUD UI renamed');
    await navigate('#/employees'); await waitText(employee.full_name);
    await click('ویرایش / پسورد'); await fill('اسم کامل', 'CRUD UI employee renamed'); await click('ثبت'); await waitText('CRUD UI employee renamed');
    await click('حذف کارمند'); await page.waitForSelector('dialog[open]'); await click('حذف کارمند');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await click('حذف‌شده‌ها / بازیابی'); await waitText('CRUD UI employee renamed');
    await click('بازیابی کارمند'); await page.waitForSelector('dialog[open]'); await click('بازیابی کارمند');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await navigate(`#/loads/${shipment.id}`); await waitText('ui.bin');
    await click('تغییر نام'); await fill('نام فایل', 'renamed-ui.bin'); await click('ثبت'); await waitText('renamed-ui.bin');
    const chooser = page.waitForFileChooser();
    await click('جایگزینی فایل');
    await (await chooser).accept([replacementPath]);
    await waitText('replacement-ui.bin');
    await click('حذف فایل'); await page.waitForSelector('dialog[open]'); await click('حذف فایل');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await click('بازیابی فایل'); await page.waitForSelector('dialog[open]'); await click('بازیابی فایل');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await click('ویرایش بار / تخصیص‌ها'); await fill('تعداد کامیون', '7'); await click('ثبت');
    await waitText('۷ کامیون');
    assert.equal((await call('GET', `/transport/shipments/${shipment.id}`)).truck_count, 7);
    await click('حذف بار'); await page.waitForSelector('dialog[open]'); await click('حذف بار');
    await page.waitForFunction((id) => location.hash === `#/companies/${id}`, {}, company.id);
    await click('حذف‌شده‌ها / بازیابی'); await waitText('CRUD UI code');
    await click('بازیابی بار'); await page.waitForSelector('dialog[open]'); await click('بازیابی بار');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await navigate(`#/companies/${company.id}`); await waitText('CRUD UI renamed');
    await click('تعریف حساب شرکت'); await fill('یوزرنیم شرکت', 'crud-ui-customer'); await fill('پسورد شرکت', DEMO_PASSWORD); await click('ثبت');
    await waitText('حساب شرکت: crud-ui-customer');
    await click('ویرایش حساب / پسورد'); await fill('یوزرنیم شرکت', 'crud-ui-customer-new'); await click('ثبت');
    await waitText('حساب شرکت: crud-ui-customer-new');
    await click('حذف حساب شرکت'); await page.waitForSelector('dialog[open]'); await click('حذف حساب شرکت');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await click('بازیابی حساب شرکت'); await page.waitForSelector('dialog[open]'); await click('بازیابی حساب شرکت');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await navigate('#/companies'); await waitText('CRUD UI renamed');
    await click('حذف شرکت'); await page.waitForSelector('dialog[open]'); await click('حذف شرکت');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    await click('حذف‌شده‌ها / بازیابی'); await waitText('CRUD UI renamed');
    await click('بازیابی شرکت'); await page.waitForSelector('dialog[open]'); await click('بازیابی شرکت');
    await page.waitForFunction(() => !document.querySelector('dialog[open]')); await page.waitForNetworkIdle({ idleTime: 100 });
    assert.deepEqual(errors, []);
  } finally { if (browser) await browser.close(); await backend.stop(); await rm(filesDir, { recursive: true, force: true }); }
});
