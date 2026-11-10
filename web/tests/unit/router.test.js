import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildHash, createRouteTable, parseHash, resolveAccess, safeNextHash } from '../../src/js/core/router.js';

test('parses hashes into path and query', () => {
  assert.deepEqual(parseHash(''), { path: '/', query: {} });
  assert.deepEqual(parseHash('#'), { path: '/', query: {} });
  assert.deepEqual(parseHash('#/'), { path: '/', query: {} });
  assert.deepEqual(parseHash('#/shipments'), { path: '/shipments', query: {} });
  assert.deepEqual(parseHash('#/shipments/'), { path: '/shipments', query: {} });
  assert.deepEqual(parseHash('#shipments'), { path: '/shipments', query: {} });
  assert.deepEqual(parseHash('#/shipments?status=ACTIVE&page=2&q=%D8%A8%D8%A7%D8%B1'), {
    path: '/shipments',
    query: { status: 'ACTIVE', page: '2', q: 'بار' },
  });
});

test('builds hashes and omits empty query values', () => {
  assert.equal(buildHash('/shipments'), '#/shipments');
  assert.equal(buildHash('/shipments', { page: 2, q: '', status: null, sort: undefined }), '#/shipments?page=2');
  assert.equal(buildHash('/shipments', { q: 'بار یخچال' }), '#/shipments?q=%D8%A8%D8%A7%D8%B1+%DB%8C%D8%AE%DA%86%D8%A7%D9%84');
  const round = parseHash(buildHash('/audit-logs', { action: 'LOGIN_FAILED', page: 3 }));
  assert.deepEqual(round, { path: '/audit-logs', query: { action: 'LOGIN_FAILED', page: '3' } });
});

test('matches routes and extracts parameters', () => {
  const table = createRouteTable([
    { path: '/shipments/new', name: 'new' },
    { path: '/shipments/:id', name: 'detail' },
    { path: '/shipments', name: 'list' },
    { path: '/a.b', name: 'dot' },
  ]);
  assert.equal(table.match('/shipments').route.name, 'list');
  assert.equal(table.match('/shipments/new').route.name, 'new');
  const detail = table.match('/shipments/8b0c2a5e-1111-4222-8333-444455556666');
  assert.equal(detail.route.name, 'detail');
  assert.deepEqual(detail.params, { id: '8b0c2a5e-1111-4222-8333-444455556666' });
  assert.deepEqual(table.match('/shipments/a%20b').params, { id: 'a b' });
  assert.deepEqual(table.match('/shipments/%E0%A4%A').params, { id: '%E0%A4%A' }); // malformed escapes are kept verbatim
  assert.equal(table.match('/shipments/1/extra'), null);
  assert.equal(table.match('/unknown'), null);
  assert.equal(table.match('/a.b').route.name, 'dot');
  assert.equal(table.match('/aXb'), null); // "." in a route is literal
});

test('guards routes by authentication and permission', () => {
  const guest = { isAuthenticated: false, can: () => false, currentHash: '#/shipments?page=2' };
  const employee = { isAuthenticated: true, can: (permission) => permission === 'shipment:view', currentHash: '#/users' };

  assert.deepEqual(resolveAccess({ path: '/track' }, guest), { action: 'render' });
  assert.deepEqual(resolveAccess({ path: '/shipments', auth: true }, guest), {
    action: 'redirect',
    to: '#/login?next=%23%2Fshipments%3Fpage%3D2',
  });
  assert.deepEqual(resolveAccess({ path: '/dashboard', auth: true }, { ...guest, currentHash: '#/' }), {
    action: 'redirect',
    to: '#/login',
  });
  assert.deepEqual(resolveAccess({ path: '/login', guestOnly: true }, employee), { action: 'redirect', to: '#/dashboard' });
  assert.deepEqual(resolveAccess({ path: '/login', guestOnly: true }, guest), { action: 'render' });
  assert.deepEqual(resolveAccess({ path: '/shipments', auth: true, permission: 'shipment:view' }, employee), { action: 'render' });
  assert.deepEqual(resolveAccess({ path: '/users', auth: true, permission: 'user:view' }, employee), { action: 'forbidden' });
});

test('only accepts in-app destinations after login', () => {
  assert.equal(safeNextHash('#/shipments?page=2'), '#/shipments?page=2');
  assert.equal(safeNextHash('#/shipments/abc'), '#/shipments/abc');
  // eslint-disable-next-line no-script-url -- the hostile value is test input, never executed
  const scriptUrl = 'javascript:alert(1)';
  for (const hostile of ['https://evil.example', '//evil.example', '#//evil.example', scriptUrl, '#/login', '#/login?next=x', '', null, undefined, 42, '#/\\evil']) {
    assert.equal(safeNextHash(hostile), '#/dashboard', String(hostile));
  }
  assert.equal(safeNextHash(null, '#/track'), '#/track');
});
