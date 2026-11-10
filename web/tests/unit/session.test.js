import assert from 'node:assert/strict';
import { test } from 'node:test';

import { SESSION_STORAGE_KEY, createMemoryStorage, createSessionStore } from '../../src/js/core/session.js';
import { authSession, clock } from './helpers.js';

test('starts empty and stores an authentication response', () => {
  const now = clock();
  const storage = createMemoryStorage();
  const session = createSessionStore({ storage, now });
  assert.equal(session.read(), null);
  assert.equal(session.isAuthenticated(), false);
  assert.equal(session.user, null);
  assert.equal(session.can('shipment:view'), false);
  assert.deepEqual(session.appSettings, {});

  session.setFromAuthResponse(authSession());
  const stored = session.read();
  assert.equal(stored.accessToken, 'access-1');
  assert.equal(stored.accessExpiresAt, now() + 900_000);
  assert.equal(stored.refreshExpiresAt, now() + 1_209_600_000);
  assert.equal(session.isAuthenticated(), true);
  assert.equal(session.user.username, 'armin.operator');
  assert.equal(session.can('shipment:view'), true);
  assert.equal(session.can('user:view'), false);
  assert.equal(session.isGlobalScope, false);
  assert.deepEqual(session.appSettings, { password: { min_length: 10 } });
});

test('is no longer authenticated once the refresh token has expired', () => {
  const now = clock();
  const session = createSessionStore({ storage: createMemoryStorage(), now });
  session.setFromAuthResponse(authSession());
  now.advance(1_209_600_000 - 1);
  assert.equal(session.isAuthenticated(), true);
  now.advance(1);
  assert.equal(session.isAuthenticated(), false);
});

test('shares state through storage and ignores corrupted content', () => {
  const storage = createMemoryStorage();
  const tabA = createSessionStore({ storage });
  const tabB = createSessionStore({ storage });
  tabA.setFromAuthResponse(authSession('A'));
  assert.equal(tabB.read().accessToken, 'access-A');
  tabB.clear();
  assert.equal(tabA.read(), null);

  for (const garbage of ['{broken', '"text"', '[]', '{}', JSON.stringify({ accessToken: 'x' }), 'null']) {
    storage.setItem(SESSION_STORAGE_KEY, garbage);
    assert.equal(tabA.read(), null, garbage);
    assert.equal(tabA.isAuthenticated(), false);
  }
});

test('updates the profile without touching the tokens', () => {
  const session = createSessionStore({ storage: createMemoryStorage() });
  session.updateProfile({ user: { username: 'ghost' }, permissions: ['x'] }); // no session: ignored
  assert.equal(session.read(), null);

  session.setFromAuthResponse(authSession());
  session.updateProfile({
    user: { id: 'u1', username: 'armin.operator', full_name: 'نام تازه', role: 'EMPLOYEE' },
    permissions: ['shipment:view', 'shipment:archive'],
  });
  assert.equal(session.user.full_name, 'نام تازه');
  assert.equal(session.can('shipment:archive'), true);
  assert.equal(session.read().accessToken, 'access-1');
  assert.deepEqual(session.appSettings, { password: { min_length: 10 } }); // kept when the profile has none
});

test('notifies subscribers about local and cross-tab changes', () => {
  const session = createSessionStore({ storage: createMemoryStorage() });
  const seen = [];
  const unsubscribe = session.subscribe((value) => seen.push(value?.accessToken ?? null));
  session.setFromAuthResponse(authSession('1'));
  session.handleStorageEvent({ key: SESSION_STORAGE_KEY });
  session.handleStorageEvent({ key: 'unrelated' });
  session.handleStorageEvent({ key: null }); // storage.clear() in another tab
  session.clear();
  unsubscribe();
  session.setFromAuthResponse(authSession('2'));
  assert.deepEqual(seen, ['access-1', 'access-1', 'access-1', null]);
});

test('keeps working when storage throws', () => {
  const storage = {
    getItem: () => {
      throw new Error('blocked');
    },
    setItem: () => {
      throw new Error('quota');
    },
    removeItem: () => {
      throw new Error('blocked');
    },
  };
  const session = createSessionStore({ storage });
  session.setFromAuthResponse(authSession());
  assert.equal(session.read(), null);
  session.clear();
  assert.equal(session.isAuthenticated(), false);
});
