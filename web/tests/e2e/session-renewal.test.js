/**
 * Token renewal against the real server.
 *
 * Refresh tokens rotate and a reused token revokes the whole session, so the client must
 * renew exactly once, even when several requests or several tabs notice the expiry together.
 * The backend runs with the shortest access-token lifetime it accepts (60 seconds).
 */

import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

import { signIn, useApp } from './support/ui.mjs';

const SESSION_KEY = 'armin-transport.session.v1';
const ACCESS_TOKEN_TTL_SECONDS = 60;
const app = useApp({ settings: { JWT_ACCESS_TOKEN_TTL_SECONDS: String(ACCESS_TOKEN_TTL_SECONDS) } });

/** Caption of the table on the shipments page (the dashboard lists the same shipments in another table). */
const SHIPMENT_LIST = 'فهرست محموله‌ها';

const readSession = async (ui) => JSON.parse(await ui.localStorage(SESSION_KEY));
const refreshCount = (...tabs) => tabs.reduce((total, tab) => total + tab.requests('/auth/refresh').length, 0);

/** Makes the client believe that its access token expires at `expiresAt` (the server is not affected). */
async function pretendAccessTokenExpiresAt(ui, expiresAt) {
  const session = await readSession(ui);
  await ui.setLocalStorage(SESSION_KEY, JSON.stringify({ ...session, accessExpiresAt: expiresAt }));
}

app.scenario('a token that is about to expire is renewed once before the next request, and a replayed token ends the session', async (ui) => {
  await ui.open('#/login');
  await signIn(ui, 'armin.operator', app.password);
  const before = await readSession(ui);
  assert.ok(before.accessExpiresAt - Date.now() <= ACCESS_TOKEN_TTL_SECONDS * 1000);
  assert.equal(refreshCount(ui), 0);

  await pretendAccessTokenExpiresAt(ui, Date.now() - 1000);
  await ui.click('محموله‌ها', { role: 'link' });
  await ui.waitForRow('مواد غذایی بسته‌بندی‌شده', SHIPMENT_LIST);

  assert.equal(refreshCount(ui), 1, 'the page sends several requests but renews the token once');
  const after = await readSession(ui);
  assert.notEqual(after.accessToken, before.accessToken);
  assert.notEqual(after.refreshToken, before.refreshToken, 'the refresh token is rotated');
  assert.equal(after.user.username, 'armin.operator');
  assert.ok(after.accessExpiresAt > Date.now());

  // Somebody replays the old (already rotated) refresh token: the server revokes the whole session.
  const replay = await fetch(`${app.apiUrl}/auth/refresh`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refresh_token: before.refreshToken }),
  });
  assert.equal(replay.status, 401);

  ui.expectHttp(401, '/dashboard/summary');
  await ui.click('داشبورد', { role: 'link' });
  await ui.waitForHash('#/login?next=%23%2Fdashboard');
  await ui.waitForToast('لطفاً دوباره وارد شوید');
  assert.equal(await ui.localStorage(SESSION_KEY), null);
});

app.scenario('two tabs that notice the expiry at the same moment renew the session only once', async (first) => {
  await first.open('#/login');
  await signIn(first, 'armin.operator', app.password);
  const second = await first.openTab();
  await second.open('#/dashboard');
  await second.waitForText('سارا محمدی، خوش آمدید');
  const before = await readSession(first);

  // Slow the renewal down so that the second tab certainly asks while the first is still waiting.
  await first.delayRequests('/auth/refresh', 400);
  await second.delayRequests('/auth/refresh', 400);
  await pretendAccessTokenExpiresAt(first, Date.now() - 1000);

  await Promise.all([first.go('#/shipments'), second.go('#/shipments')]);
  await first.waitForRow('مواد غذایی بسته‌بندی‌شده', SHIPMENT_LIST);
  await second.waitForRow('مواد غذایی بسته‌بندی‌شده', SHIPMENT_LIST);

  assert.equal(refreshCount(first, second), 1, 'only one tab may spend the refresh token');
  const after = await readSession(second);
  assert.notEqual(after.refreshToken, before.refreshToken);
  assert.deepEqual(await readSession(first), after, 'both tabs use the same renewed session');

  // The tabs share one session: signing out in one of them signs the other one out as well.
  await first.click('خروج');
  await first.waitForHash('#/login');
  await second.waitForHash('#/login?next=%23%2Fshipments');
  assert.ok(!(await second.hasText('مواد غذایی')));
});

app.scenario('when the server reports the token as expired, the request is repeated with a renewed token', async (ui) => {
  await ui.open('#/login');
  await signIn(ui, 'armin.operator', app.password);
  const before = await readSession(ui);

  // The client is told that the token is good for another hour, so it will not renew it on its own.
  await pretendAccessTokenExpiresAt(ui, Date.now() + 3_600_000);
  await sleep(before.accessExpiresAt - Date.now() + 2000);

  ui.expectHttp(401, '/api/v1/shipments');
  await ui.click('محموله‌ها', { role: 'link' });
  await ui.waitForRow('مواد غذایی بسته‌بندی‌شده', SHIPMENT_LIST);

  assert.equal(refreshCount(ui), 1);
  assert.equal(await ui.hash(), '#/shipments');
  const after = await readSession(ui);
  assert.notEqual(after.accessToken, before.accessToken);
  assert.ok(after.accessExpiresAt - Date.now() <= ACCESS_TOKEN_TTL_SECONDS * 1000, 'the real lifetime is stored again');
});
