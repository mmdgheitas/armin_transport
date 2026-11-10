/** The staff application on a phone: drawer navigation, folded filters, and pages and dialogs that fit the screen. */

import assert from 'node:assert/strict';

import { DESKTOP, PHONE, eventually, signIn, useApp } from './support/ui.mjs';

const app = useApp();

const SHIPMENT_LIST = 'فهرست محموله‌ها';
const SECTIONS = ['داشبورد', 'محموله‌ها', 'شرکت‌ها', 'کاربران', 'فیلدهای محموله', 'گزارش رویدادها'];

/** Names of the section links a user can reach right now. */
const reachableSections = async (ui) => (await ui.names('link')).filter((name) => SECTIONS.includes(name));

const drawerOpens = (ui) => eventually(async () => (await reachableSections(ui)).length === SECTIONS.length, 'the drawer shows every section');
const drawerCloses = (ui) => eventually(async () => (await reachableSections(ui)).length === 0, 'the drawer is closed and its links are out of reach');

app.scenario(
  'on a phone the navigation is a drawer behind the menu button',
  async (ui) => {
    await ui.open('#/dashboard');
    await signIn(ui, 'admin', app.password);
    await ui.waitForText('مدیر سامانه، خوش آمدید');
    assert.deepEqual(await reachableSections(ui), [], 'while closed, the drawer cannot be reached with the keyboard or a screen reader');
    assert.equal(await ui.attribute('فهرست اصلی', 'aria-expanded'), 'false');

    // Opening moves the focus into the drawer, onto the page that is shown.
    await ui.click('فهرست اصلی');
    await drawerOpens(ui);
    assert.equal(await ui.attribute('فهرست اصلی', 'aria-expanded'), 'true');
    assert.equal(await ui.focused(), 'داشبورد');
    await ui.screenshot('phone-menu');

    // Choosing a section goes there and closes the drawer.
    await ui.click('کاربران', { role: 'link' });
    assert.equal(await ui.hash(), '#/users');
    await ui.waitForRow('سارا محمدی', 'فهرست کاربران');
    await drawerCloses(ui);
    assert.equal(await ui.attribute('فهرست اصلی', 'aria-expanded'), 'false');

    // Escape closes it and gives the focus back to the menu button.
    await ui.click('فهرست اصلی');
    await drawerOpens(ui);
    assert.equal(await ui.focused(), 'کاربران');
    await ui.page.keyboard.press('Escape');
    await drawerCloses(ui);
    assert.equal(await ui.focused(), 'فهرست اصلی');
    assert.equal(await ui.hash(), '#/users');

    // So does a tap beside it.
    await ui.click('فهرست اصلی');
    await drawerOpens(ui);
    await ui.page.mouse.click(24, 420);
    await drawerCloses(ui);
    assert.equal(await ui.hash(), '#/users');

    // The account links keep their names although only their icons are shown.
    await ui.click('حساب کاربری', { role: 'link' });
    assert.equal(await ui.hash(), '#/profile');
    await ui.click('خروج');
    await ui.waitForHash('#/login');
  },
  { viewport: PHONE },
);

app.scenario(
  'on a phone the filters are folded away until they are needed',
  async (ui) => {
    await ui.open('#/shipments');
    await signIn(ui, 'armin.operator', app.password, { landing: '#/shipments' });
    await ui.waitForRow('مواد غذایی بسته‌بندی‌شده', SHIPMENT_LIST);
    assert.ok(!(await ui.has('جست‌وجو', { role: 'field' })), 'the results come first; the filter form is folded');

    await ui.click('فیلترها');
    await ui.fill('جست‌وجو', 'خودرو');
    await ui.assertLayout('open filters on a phone');
    await ui.screenshot('phone-filters');
    await ui.click('اعمال فیلتر');
    await ui.waitForHash(/^#\/shipments\?q=/);
    await eventually(async () => (await ui.table(SHIPMENT_LIST)).rows.length === 1, 'only the matching shipment is listed');

    // While a filter is in force the form stays open and says so.
    assert.ok(await ui.has('فیلترها (فعال)'));
    assert.equal(await ui.value('جست‌وجو'), 'خودرو');
    const row = await ui.row('قطعات یدکی خودرو', SHIPMENT_LIST);
    assert.equal(row['وضعیت'], 'فعال');
    assert.deepEqual(Object.keys(row), ['کد رهگیری', 'توضیحات', 'سندها', 'وضعیت', 'تاریخ ثبت'], 'secondary columns are left out on a narrow screen');
    await ui.assertLayout('filtered list on a phone');

    await ui.click('حذف فیلترها', { role: 'link' });
    assert.equal(await ui.hash(), '#/shipments');
    await ui.waitForRow('مواد غذایی بسته‌بندی‌شده', SHIPMENT_LIST);
    assert.ok(!(await ui.has('جست‌وجو', { role: 'field' })));
  },
  { viewport: PHONE },
);

/** Visits every staff page and opens every dialog, checking the layout rules on each. */
async function walkThrough(ui, shipmentId, shot) {
  const page = async (hash, landmark, name) => {
    await ui.go(hash);
    await ui.waitForText(landmark);
    await ui.assertLayout(name);
    if (shot) await ui.screenshot(`${shot}-${name}`);
  };
  const dialog = async (opener, landmark, name, options = {}) => {
    await ui.click(opener, options);
    await ui.waitForText(landmark);
    await ui.assertLayout(`${name} dialog`);
    if (shot) await ui.screenshot(`${shot}-${name}-dialog`);
    await ui.click('بستن');
    await eventually(async () => !(await ui.has('بستن')), `the ${name} dialog closes`);
  };

  await page('#/dashboard', 'آخرین محموله‌ها', 'dashboard');
  await page('#/shipments', 'تجهیزات پزشکی', 'shipments');
  await page('#/shipments/new', 'اطلاعات محموله', 'new-shipment');

  await page(`#/shipments/${shipmentId}`, 'مقادیر ثبت‌شده برای این محموله', 'shipment');
  await dialog('ویرایش توضیحات', 'انصراف', 'edit-description');
  await dialog('تغییر کد رهگیری', 'کد فعلی', 'change-code');
  await dialog('بایگانی', 'بایگانی شود', 'archive');
  await ui.click('ویرایش مشخصات');
  await ui.waitForText('ذخیرهٔ مشخصات');
  await ui.assertLayout('goods form');
  if (shot) await ui.screenshot(`${shot}-goods-form`);
  await page(`#/shipments/${shipmentId}?tab=documents`, 'هنوز سندی برای این محموله بارگذاری نشده است.', 'shipment-documents');
  await page(`#/shipments/${shipmentId}?tab=history`, 'ثبت اولیه', 'shipment-history');

  await page('#/companies', 'باربری پارس', 'companies');
  await dialog('شرکت جدید', 'شرکت فعال است', 'new-company');
  await dialog('ویرایش باربری پارس', 'برای این شرکت ثبت شده است', 'edit-company');

  await page('#/users', 'سارا محمدی', 'users');
  await dialog('کارمند جدید', 'رمز عبور اولیه', 'new-user');
  await dialog('بازنشانی رمز سارا محمدی', 'رمز عبور جدید', 'reset-password');

  await page('#/product-fields', 'خدمات جانبی', 'goods-fields');
  await dialog('فیلد جدید', 'قواعد اعتبارسنجی', 'new-field');
  await dialog('ویرایش فیلد خدمات جانبی', 'گزینه‌ها', 'edit-field');

  await page('#/audit-logs', 'ورود موفق', 'audit-log');
  await dialog('نمایش جزئیات رویداد', 'شناسهٔ درخواست', 'audit-entry', { index: 0 });

  await page('#/profile', 'تغییر رمز عبور', 'profile');
}

for (const [device, viewport, shot] of [
  ['a phone', PHONE, 'phone'],
  ['a desktop screen', DESKTOP, null],
]) {
  app.scenario(
    `on ${device} every page and dialog fits the screen and names all its controls`,
    async (ui) => {
      const token = await app.api.login('admin');
      const shipment = (await app.api.list('/shipments', token)).find((item) => item.description === 'تجهیزات پزشکی');
      await ui.open('#/dashboard');
      await signIn(ui, 'admin', app.password);
      await walkThrough(ui, shipment.id, shot);
    },
    { viewport },
  );
}
