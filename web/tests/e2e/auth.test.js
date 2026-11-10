/** Signing in and out, what each role may open, and what happens when an account is switched off. */

import assert from 'node:assert/strict';

import { signIn, useApp } from './support/ui.mjs';

const SESSION_KEY = 'armin-transport.session.v1';
const app = useApp();

app.scenario('an employee signs in, stays signed in across reloads and signs out', async (ui) => {
  await ui.open('#/login');

  // Nothing is sent while the form is incomplete.
  await ui.click('ورود');
  await ui.waitForError('نام کاربری', 'نام کاربری را وارد کنید.');
  await ui.waitForError('رمز عبور', 'رمز عبور را وارد کنید.');
  assert.deepEqual(ui.requests('/api/'), []);

  ui.expectHttp(401, '/auth/login');
  await ui.fill('نام کاربری', 'armin.operator');
  await ui.fill('رمز عبور', 'not-the-password');
  await ui.click('ورود');
  await ui.waitForText('نام کاربری یا رمز عبور نادرست است.');
  assert.equal(await ui.hash(), '#/login');
  assert.equal(await ui.localStorage(SESSION_KEY), null);

  // The password is masked until the user asks to see it.
  const passwordType = () => ui.page.evaluate(() => document.querySelector('input[autocomplete="current-password"]').type);
  assert.equal(await passwordType(), 'password');
  await ui.click('نمایش رمز عبور');
  assert.equal(await passwordType(), 'text');
  await ui.click('پنهان کردن رمز عبور');
  assert.equal(await passwordType(), 'password');

  await ui.fill('رمز عبور', app.password);
  await ui.click('ورود');
  await ui.waitForHash('#/dashboard');
  await ui.waitForText('سارا محمدی، خوش آمدید');
  await ui.waitForText('خلاصهٔ وضعیت حمل‌ونقل آرمین');
  assert.equal(ui.requests('/dashboard/summary').length, 1, 'the dashboard is loaded once after signing in');

  const stored = JSON.parse(await ui.localStorage(SESSION_KEY));
  assert.equal(stored.user.username, 'armin.operator');
  assert.equal('password' in stored.user, false);

  await ui.reload();
  await ui.waitForText('سارا محمدی، خوش آمدید');

  // A signed-in user has no use for the login form.
  await ui.go('#/login');
  await ui.waitForHash('#/dashboard');

  await ui.click('خروج');
  await ui.waitForHash('#/login');
  await ui.waitForToast('از حساب کاربری خود خارج شدید.');
  assert.equal(await ui.localStorage(SESSION_KEY), null);

  // The session is dead on the server too, and the back button does not bring the panel back.
  const replay = await fetch(`${app.apiUrl}/auth/refresh`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refresh_token: stored.refreshToken }),
  });
  assert.equal(replay.status, 401);
  const reuse = await fetch(`${app.apiUrl}/auth/me`, { headers: { Authorization: `Bearer ${stored.accessToken}` } });
  assert.equal(reuse.status, 401);

  await ui.back();
  await ui.waitForHash('#/login?next=%23%2Fdashboard');
  assert.ok(!(await ui.hasText('خوش آمدید')));
});

app.scenario('after signing in the user arrives at the page that was asked for', async (ui) => {
  await ui.open('#/shipments?status=ACTIVE');
  await ui.waitForHash('#/login?next=%23%2Fshipments%3Fstatus%3DACTIVE');
  await signIn(ui, 'armin.operator', app.password, { landing: '#/shipments?status=ACTIVE' });
  await ui.waitForText('محموله‌های شرکت شما');
  assert.equal(await ui.value('وضعیت'), 'ACTIVE', 'the filter from the address is applied');
  assert.equal(ui.requests('/dashboard/summary').length, 0, 'the dashboard is not loaded on the way');
});

app.scenario('a destination outside the application is ignored after signing in', async (ui) => {
  const scriptUrl = ['javascript', 'alert(1)'].join(':');
  for (const next of ['https://evil.example/', '//evil.example', '#//evil.example', scriptUrl]) {
    await ui.open(`#/login?next=${encodeURIComponent(next)}`);
    await signIn(ui, 'armin.clerk', app.password);
    assert.ok(ui.page.url().startsWith(`${app.baseUrl}/#/dashboard`), `next=${next} led to ${ui.page.url()}`);
    await ui.click('خروج');
    await ui.waitForHash('#/login');
  }
});

app.scenario('an employee sees only the pages of the employee role', async (ui) => {
  await ui.open('#/login');
  await signIn(ui, 'armin.operator', app.password);
  const navigation = await ui.page.evaluate(() => [...document.querySelectorAll('nav a')].map((link) => link.textContent.trim()));
  assert.deepEqual(navigation, ['داشبورد', 'محموله‌ها']);

  for (const page of ['#/companies', '#/users', '#/product-fields', '#/audit-logs']) {
    await ui.go(page);
    await ui.waitForText('شما اجازهٔ مشاهدهٔ این صفحه را ندارید.');
  }
  for (const route of ['/companies', '/users', '/audit-logs']) {
    assert.deepEqual(ui.requests(`/api/v1${route}`), [], `the client must not even ask for ${route}`);
  }

  await ui.go('#/profile');
  const profile = await ui.definitions();
  assert.equal(profile['نام'], 'سارا محمدی');
  assert.equal(profile['نام کاربری'], 'armin.operator');
  assert.equal(profile['نقش'], 'کارمند');
  assert.equal(profile['شرکت'], 'حمل‌ونقل آرمین');
});

app.scenario('the administrator sees every section', async (ui) => {
  await ui.open('#/login');
  await signIn(ui, 'admin', app.password);
  await ui.waitForText('خلاصهٔ وضعیت همهٔ شرکت‌ها');
  const navigation = await ui.page.evaluate(() => [...document.querySelectorAll('nav a')].map((link) => link.textContent.trim()));
  assert.deepEqual(navigation, ['داشبورد', 'محموله‌ها', 'شرکت‌ها', 'کاربران', 'فیلدهای محموله', 'گزارش رویدادها']);

  for (const [page, heading] of [
    ['#/shipments', 'محموله‌ها'],
    ['#/companies', 'شرکت‌ها'],
    ['#/users', 'کاربران'],
    ['#/product-fields', 'فیلدهای محموله'],
    ['#/audit-logs', 'گزارش رویدادها'],
  ]) {
    await ui.go(page);
    assert.equal((await ui.headings())[0], heading);
    await ui.assertLayout(page);
    assert.equal(await ui.page.evaluate(() => document.querySelector('nav a[aria-current="page"]')?.textContent.trim()), heading);
  }
});

app.scenario('a user changes the password from the profile page', async (ui) => {
  const newPassword = 'Tazeh-Ramz-4821!';
  await ui.open('#/login');
  await signIn(ui, 'armin.clerk', app.password);
  await ui.go('#/profile');

  await ui.fill('رمز عبور فعلی', app.password);
  await ui.fill('رمز عبور جدید', newPassword);
  await ui.fill('تکرار رمز عبور جدید', `${newPassword}x`);
  await ui.click('تغییر رمز عبور');
  await ui.waitForError('تکرار رمز عبور جدید', 'تکرار رمز عبور با رمز جدید یکسان نیست.');
  assert.deepEqual(ui.requests('/auth/change-password'), []);

  ui.expectHttp(422, '/auth/change-password');
  await ui.fill('رمز عبور فعلی', 'wrong-current-password');
  await ui.fill('تکرار رمز عبور جدید', newPassword);
  await ui.click('تغییر رمز عبور');
  await ui.waitForError('رمز عبور فعلی', 'رمز عبور فعلی نادرست است.');

  // A password that contains the user name is refused by the server and explained next to the field.
  await ui.fill('رمز عبور فعلی', app.password);
  await ui.fill('رمز عبور جدید', 'armin.clerk-2026!');
  await ui.fill('تکرار رمز عبور جدید', 'armin.clerk-2026!');
  await ui.click('تغییر رمز عبور');
  await ui.waitForError('رمز عبور جدید', 'نام کاربری');

  await ui.fill('رمز عبور جدید', newPassword);
  await ui.fill('تکرار رمز عبور جدید', newPassword);
  await ui.click('تغییر رمز عبور');
  await ui.waitForToast('رمز عبور');
  assert.equal(await ui.value('رمز عبور فعلی'), '', 'the form is emptied after success');

  // The current tab stays signed in with fresh tokens; the old password stops working.
  await ui.go('#/shipments');
  await ui.waitForText('محموله‌های شرکت شما');
  await ui.click('خروج');
  await ui.waitForHash('#/login');

  ui.expectHttp(401, '/auth/login');
  await ui.fill('نام کاربری', 'armin.clerk');
  await ui.fill('رمز عبور', app.password);
  await ui.click('ورود');
  await ui.waitForText('نام کاربری یا رمز عبور نادرست است.');
  await ui.fill('رمز عبور', newPassword);
  await ui.click('ورود');
  await ui.waitForHash('#/dashboard');
});

app.scenario('switching an account off ends its session at the next request', async (ui) => {
  const admin = await app.api.login('admin');
  const employee = (await app.api.list('/users', admin)).find((user) => user.username === 'pars.operator');

  await ui.open('#/login');
  await signIn(ui, 'pars.operator', app.password);
  await ui.waitForText('مریم احمدی، خوش آمدید');

  await app.api.call('PATCH', `/users/${employee.id}`, { token: admin, json: { is_active: false } });

  ui.expectHttp(401, '/api/v1/shipments');
  await ui.click('محموله‌ها', { role: 'link' });
  await ui.waitForHash('#/login?next=%23%2Fshipments');
  await ui.waitForToast('لطفاً دوباره وارد شوید');
  assert.equal(await ui.localStorage(SESSION_KEY), null);
  assert.ok(!(await ui.hasText('مریم احمدی')), 'nothing of the panel is left on screen');

  ui.expectHttp(403, '/auth/login');
  await ui.fill('نام کاربری', 'pars.operator');
  await ui.fill('رمز عبور', app.password);
  await ui.click('ورود');
  await ui.waitForText('حساب کاربری شما غیرفعال است. با مدیر سامانه تماس بگیرید.');

  await app.api.call('PATCH', `/users/${employee.id}`, { token: admin, json: { is_active: true } });
  await ui.click('ورود');
  await ui.waitForHash('#/shipments');
  await ui.waitForText('محموله‌های شرکت شما');
});
