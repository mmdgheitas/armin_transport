import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ROUTES, NAV_ITEMS } from '../../src/js/routes.js';
import { resolveAccess } from '../../src/js/core/router.js';

test('login is the only guest page; transport details require login', () => {
  assert.deepEqual(ROUTES.filter((route) => !route.auth).map((route) => route.path), ['/login']);
  const detail = ROUTES.find((route) => route.path === '/loads/:id');
  const result = resolveAccess(detail, { isAuthenticated: false, can: () => false, currentHash: '#/loads/123' });
  assert.equal(result.action, 'redirect');
  assert.ok(result.to.startsWith('#/login'));
});

test('transport workspace has no sidebar, activity, public tracking or global shipments route', () => {
  assert.deepEqual(NAV_ITEMS, []);
  for (const path of ['/company-activity', '/track', '/shipments', '/audit-logs', '/product-fields']) {
    assert.equal(ROUTES.some((route) => route.path === path), false);
  }
  const employees = ROUTES.find((route) => route.path === '/employees');
  assert.equal(resolveAccess(employees, { isAuthenticated: true, can: () => false }).action, 'forbidden');
  assert.ok(ROUTES.some((route) => route.path === '/companies/:companyId'));
});
