/** Goods fields defined by the administrator and their effect on the shipment forms. */

import assert from 'node:assert/strict';

import { eventually, fa, signIn, useApp } from './support/ui.mjs';

const app = useApp();

const FIELD_LIST = 'فیلدهای محموله';

async function signInAsAdmin(ui, hash) {
  await ui.open(hash);
  await signIn(ui, 'admin', app.password, { landing: hash });
}

app.scenario('a changed field marks stored values for review and a deactivated field leaves the forms', async (ui) => {
  const token = await app.api.login('admin');
  const shipment = (await app.api.list('/shipments', token)).find((item) => item.description === 'مواد غذایی بسته‌بندی‌شده');
  await signInAsAdmin(ui, '#/product-fields');
  await ui.waitForRow('تعداد بسته', FIELD_LIST);

  await ui.click('ویرایش فیلد تعداد بسته');
  await ui.waitForText('نسخهٔ فیلد را افزایش می‌دهد');
  assert.equal(await ui.isEnabled('کلید فیلد', { role: 'field' }), false, 'the key of a field never changes');
  assert.equal(await ui.isEnabled('نوع داده', { role: 'field' }), false, 'the type of a field never changes');
  assert.equal(await ui.value('حداکثر مقدار'), '100000');
  await ui.fill('برچسب', 'تعداد کارتن');
  await ui.click('ذخیرهٔ تغییرات');
  await ui.waitForToast('فیلد به‌روزرسانی شد.');
  await ui.waitForRow('تعداد کارتن', FIELD_LIST);

  await ui.click('ویرایش فیلد شکستنی');
  await ui.setChecked('فیلد فعال است', false);
  await ui.click('ذخیرهٔ تغییرات');
  await ui.waitForToast('فیلد به‌روزرسانی شد.');
  await eventually(async () => (await ui.row('شکستنی', FIELD_LIST))?.['وضعیت'] === 'غیرفعال', 'the field is shown as inactive');

  await ui.select('وضعیت', 'فقط فعال');
  await ui.click('اعمال فیلتر');
  await ui.waitForHash('#/product-fields?active=1');
  await ui.waitForRow('تعداد کارتن', FIELD_LIST);
  assert.equal(await ui.row('شکستنی', FIELD_LIST), null);

  // An existing shipment keeps every stored value and says which ones need another look.
  await ui.go(`#/shipments/${shipment.id}`);
  await ui.waitForText('مقادیر ثبت‌شده برای این محموله');
  let shown = await ui.definitions();
  assert.equal(shown['تعداد کارتن نیازمند بازبینی'], '۲۴');
  assert.equal(shown['شکستنی فیلد غیرفعال'], 'خیر');
  assert.equal(shown['نام کالا'], 'مواد غذایی بسته‌بندی‌شده');
  await ui.screenshot('shipment-outdated-values');

  await ui.click('ویرایش مشخصات');
  assert.equal(await ui.value('تعداد کارتن'), '24');
  assert.ok(!(await ui.has('شکستنی', { role: 'field' })), 'a deactivated field is not asked for any more');
  await ui.click('ذخیرهٔ مشخصات');
  await ui.waitForToast('مشخصات کالا ذخیره شد.');
  await ui.waitForText('مقادیر ثبت‌شده برای این محموله');
  shown = await ui.definitions();
  assert.equal(shown['تعداد کارتن'], '۲۴', 'saving confirms the value against the current definition');
  assert.equal(shown['شکستنی فیلد غیرفعال'], 'خیر', 'the value of the deactivated field is kept');
});

app.scenario('new goods fields appear in the shipment form and their rules are enforced', async (ui) => {
  await signInAsAdmin(ui, '#/product-fields');
  await ui.waitForRow('وزن (کیلوگرم)', FIELD_LIST);
  await ui.assertLayout('goods fields');

  // A number with limits, shown to customers.
  await ui.click('فیلد جدید');
  await ui.fill('برچسب', 'دمای نگهداری (سانتی‌گراد)');
  await ui.fill('کلید فیلد', 'Storage Temp');
  await ui.click('تعریف فیلد');
  await ui.waitForError('کلید فیلد', 'کلید باید با حرف کوچک انگلیسی شروع شود');
  await ui.fill('کلید فیلد', 'storage_temp');
  await ui.select('نوع داده', 'عدد صحیح');
  await ui.fill('حداقل مقدار', 'هشت');
  await ui.click('تعریف فیلد');
  await ui.waitForError('حداقل مقدار', 'یک عدد صحیح معتبر وارد کنید.');

  ui.expectHttp(422, '/api/v1/product-fields');
  await ui.fill('حداقل مقدار', '۸');
  await ui.fill('حداکثر مقدار', '۲');
  await ui.click('تعریف فیلد');
  await ui.waitForText('حداقل مقدار نمی‌تواند بیشتر از حداکثر مقدار باشد.');

  await ui.fill('حداقل مقدار', '-۲۵');
  await ui.fill('حداکثر مقدار', '۸');
  await ui.fill('ترتیب نمایش', '۲۵');
  await ui.setChecked('به مشتری نمایش داده شود', true);
  await ui.screenshot('field-modal');
  await ui.click('تعریف فیلد');
  await ui.waitForToast('فیلد با موفقیت تعریف شد.');
  const temperature = await ui.waitForRow('دمای نگهداری', FIELD_LIST);
  assert.equal(temperature['کلید'], 'storage_temp');
  assert.equal(temperature['نوع'], 'عدد صحیح');
  assert.equal(temperature['ترتیب'], '۲۵');
  assert.equal(temperature['نمایش به مشتری'], 'قابل مشاهده');
  assert.ok(temperature['برچسب'].includes('حداقل −۲۵ · حداکثر ۸'), temperature['برچسب']);

  // A required choice between two options.
  await ui.click('فیلد جدید');
  await ui.fill('برچسب', 'نوع وسیلهٔ حمل');
  await ui.fill('کلید فیلد', 'vehicle_type');
  await ui.select('نوع داده', 'انتخاب تکی');
  await ui.click('تعریف فیلد');
  await ui.waitForText('برای فیلد انتخابی دست‌کم یک گزینه لازم است.');
  await ui.fill('مقدار گزینه', 'truck');
  await ui.click('تعریف فیلد');
  await ui.waitForText('برای هر گزینه هم مقدار و هم برچسب را وارد کنید.');
  await ui.fill('برچسب گزینه', 'کامیون');
  await ui.click('افزودن گزینه');
  await ui.fill('مقدار گزینه', 'trailer', { index: 1 });
  await ui.fill('برچسب گزینه', 'تریلی', { index: 1 });
  await ui.click('افزودن گزینه');
  await ui.fill('مقدار گزینه', 'van', { index: 2 });
  await ui.fill('برچسب گزینه', 'وانت', { index: 2 });
  await ui.click('حذف گزینه', { index: 2 });
  await ui.fill('ترتیب نمایش', '۲۶');
  await ui.setChecked('وارد کردن این فیلد الزامی است', true);
  await ui.click('تعریف فیلد');
  await ui.waitForToast('فیلد با موفقیت تعریف شد.');
  const vehicle = await ui.waitForRow('نوع وسیلهٔ حمل', FIELD_LIST);
  assert.equal(vehicle['نوع'], `انتخاب تکی (${fa(2)} گزینه)`);
  assert.equal(vehicle['الزامی'], 'الزامی');
  assert.equal(vehicle['نمایش به مشتری'], 'پنهان');

  // The same key cannot be defined twice.
  ui.expectHttp(409, '/api/v1/product-fields');
  await ui.click('فیلد جدید');
  await ui.fill('برچسب', 'وسیله');
  await ui.fill('کلید فیلد', 'vehicle_type');
  await ui.click('تعریف فیلد');
  await ui.waitForText('فیلد فعال دیگری با همین کلید وجود دارد.');
  await ui.click('انصراف');

  // The shipment form asks for the new fields; the administrator also chooses the company.
  await ui.go('#/shipments/new');
  await ui.select('شرکت', 'باربری پارس (PARS)');
  assert.deepEqual(await ui.options('نوع وسیلهٔ حمل'), ['انتخاب نشده', 'کامیون', 'تریلی']);
  await ui.fill('نام کالا', 'داروی یخچالی');
  await ui.fill('دمای نگهداری (سانتی‌گراد)', '۱۲');
  await ui.click('ثبت محموله');
  await ui.waitForError('نوع وسیلهٔ حمل', 'وارد کردن این فیلد الزامی است.');

  ui.expectHttp(422, '/api/v1/shipments');
  await ui.select('نوع وسیلهٔ حمل', 'تریلی');
  await ui.click('ثبت محموله');
  await ui.waitForError('دمای نگهداری (سانتی‌گراد)', 'مقدار نباید بیشتر از ۸ باشد.');

  await ui.fill('دمای نگهداری (سانتی‌گراد)', '-۱۸');
  await ui.click('ثبت محموله');
  await ui.waitForToast('محموله با موفقیت ثبت شد.');
  await ui.waitForHash(/^#\/shipments\/[0-9a-f-]{36}$/);
  await ui.waitForText('مقادیر ثبت‌شده برای این محموله');
  const shown = await ui.definitions();
  assert.equal(shown['شرکت'], 'باربری پارس');
  assert.equal(shown['ثبت‌کننده'], 'مدیر سامانه');
  assert.equal(shown['دمای نگهداری (سانتی‌گراد)'], '−۱۸');
  assert.equal(shown['نوع وسیلهٔ حمل'], 'تریلی');
  await ui.screenshot('shipment-detail-admin');

  // The customer sees the released temperature but not the vehicle.
  const id = (await ui.hash()).split('/').pop();
  const token = await app.api.login('admin');
  const shipment = await app.api.call('GET', `/shipments/${id}`, { token });
  const grant = await app.api.call('POST', '/customer/lookup', { json: { tracking_code: shipment.tracking_code } });
  const customer = await app.api.call('GET', `/customer/access/${grant.access_token}/shipment`);
  const details = Object.fromEntries(customer.product_details.map((detail) => [detail.label, detail.value]));
  assert.equal(details['دمای نگهداری (سانتی‌گراد)'], -18);
  assert.ok(!('نوع وسیلهٔ حمل' in details));

  // Relaxing the requirement takes effect in the form at once.
  await ui.go('#/product-fields');
  await ui.click('ویرایش فیلد نوع وسیلهٔ حمل');
  assert.equal(await ui.value('مقدار گزینه', { index: 1 }), 'trailer');
  await ui.setChecked('وارد کردن این فیلد الزامی است', false);
  await ui.click('ذخیرهٔ تغییرات');
  await ui.waitForToast('فیلد به‌روزرسانی شد.');
  await eventually(async () => (await ui.row('نوع وسیلهٔ حمل', FIELD_LIST))?.['الزامی'] === 'اختیاری', 'the field is shown as optional');
  await ui.go('#/shipments/new');
  await ui.select('شرکت', 'باربری پارس (PARS)');
  await ui.fill('نام کالا', 'بار بدون وسیلهٔ مشخص');
  await ui.click('ثبت محموله');
  await ui.waitForToast('محموله با موفقیت ثبت شد.');
});
