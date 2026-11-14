import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ROUTES, NAV_ITEMS } from '../../src/js/routes.js';
import { resolveAccess } from '../../src/js/core/router.js';

test('login is the only guest page; tracking cannot be rendered before login', () => {
  assert.deepEqual(ROUTES.filter((route) => !route.auth).map((route) => route.path), ['/login']);
  const track = ROUTES.find((route) => route.path === '/track');
  const result = resolveAccess(track, { isAuthenticated: false, can: () => false, currentHash: '#/track' });
  assert.equal(result.action, 'redirect');
  assert.ok(result.to.startsWith('#/login'));
});

test('company history is guarded and visible in the company navigation', () => {
  const activity = ROUTES.find((route) => route.path === '/company-activity');
  assert.equal(activity.auth, true);
  assert.equal(activity.permission, 'company_activity:view');
  assert.ok(NAV_ITEMS.some((entry) => entry.path === '/company-activity' && entry.permission === activity.permission));
  assert.equal(resolveAccess(activity, { isAuthenticated: true, can: () => false }).action, 'forbidden');
  assert.equal(resolveAccess(activity, { isAuthenticated: true, can: (permission) => permission === 'company_activity:view' }).action, 'render');
});
