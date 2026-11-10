import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ApiError, createApiClient, filenameFromContentDisposition, isAbortError } from '../../src/js/core/api.js';
import { createMemoryStorage, createSessionStore } from '../../src/js/core/session.js';
import { authSession, clock, fail, fakeFetch, fakeLocks, jsonResponse, ok } from './helpers.js';

function setup(handler, { loggedIn = true, locks = null, storage = createMemoryStorage(), now = clock() } = {}) {
  const session = createSessionStore({ storage, now });
  if (loggedIn && session.read() === null) session.setFromAuthResponse(authSession('1'));
  const { fetchImpl, calls } = fakeFetch(handler);
  const ended = [];
  const api = createApiClient({ baseUrl: '/api/v1/', session, fetchImpl, locks, now, onSessionEnded: (error) => ended.push(error) });
  return { api, session, calls, ended, now, storage };
}

test('sends JSON with the bearer token and unwraps the envelope', async () => {
  const { api, calls } = setup(() => ok({ id: 's1' }, 'محموله ثبت شد.', 201));
  const result = await api.post('/shipments', { json: { description: 'بار' }, query: { dry: '', page: 2, skip: null } });
  assert.deepEqual(result, { data: { id: 's1' }, message: 'محموله ثبت شد.' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'POST');
  assert.equal(calls[0].url, '/api/v1/shipments?page=2');
  assert.equal(calls[0].headers.Authorization, 'Bearer access-1');
  assert.equal(calls[0].headers['Content-Type'], 'application/json');
  assert.deepEqual(calls[0].body, { description: 'بار' });
  assert.equal(calls[0].init.credentials, 'omit'); // bearer tokens only; cookies are never sent
});

test('public requests carry no token and work without a session', async () => {
  const { api, calls, ended } = setup(() => ok({ access_token: 'customer' }), { loggedIn: false });
  await api.post('/customer/lookup', { auth: false, json: { tracking_code: 'ABCD-1234' } });
  assert.equal('Authorization' in calls[0].headers, false);
  assert.deepEqual(ended, []);
});

test('multipart bodies are passed through untouched', async () => {
  const { api, calls } = setup(() => ok([], 'بارگذاری شد.', 201));
  const formData = new FormData();
  formData.append('files', new Blob(['x']), 'a.pdf');
  await api.post('/shipments/s1/documents', { formData });
  assert.equal(calls[0].init.body, formData);
  assert.equal('Content-Type' in calls[0].headers, false); // the browser adds the boundary
});

test('turns error envelopes into ApiError', async () => {
  const { api } = setup(() =>
    fail(422, 'validation_error', 'اطلاعات واردشده معتبر نیست.', { fields: { username: ['الزامی است.'] } }),
  );
  await assert.rejects(api.post('/users', { json: {} }), (error) => {
    assert.ok(error instanceof ApiError);
    assert.equal(error.status, 422);
    assert.equal(error.code, 'validation_error');
    assert.equal(error.message, 'اطلاعات واردشده معتبر نیست.');
    assert.deepEqual(error.fields, { username: ['الزامی است.'] });
    assert.equal(error.requestId, 'req-test-0001');
    assert.equal(error.isValidation, true);
    assert.equal(error.isNotFound, false);
    return true;
  });
});

test('exposes rate-limit and permission details', async () => {
  const limited = setup(() => fail(429, 'rate_limited', 'تعداد درخواست‌ها بیش از حد مجاز است.', { retry_after_seconds: 42 }));
  await assert.rejects(limited.api.get('/shipments'), (error) => error.retryAfterSeconds === 42 && error.status === 429);
  assert.notEqual(limited.session.read(), null); // a rate limit never ends the session

  const denied = setup(() => fail(403, 'permission_denied', 'اجازهٔ این کار را ندارید.', { required_permissions: ['user:view'] }));
  await assert.rejects(denied.api.get('/users'), (error) => error.requiredPermissions[0] === 'user:view');
  assert.notEqual(denied.session.read(), null);
});

test('reports network failures and non-JSON responses with Persian messages', async () => {
  const offline = setup(() => {
    throw new TypeError('fetch failed');
  });
  await assert.rejects(offline.api.get('/shipments'), (error) => {
    assert.equal(error.code, 'network_error');
    assert.equal(error.isNetworkError, true);
    assert.equal(error.status, 0);
    assert.match(error.message, /ارتباط با سرور/);
    return true;
  });
  assert.notEqual(offline.session.read(), null);

  const gateway = setup(() => new Response('<html>502 Bad Gateway</html>', { status: 502, headers: { 'Content-Type': 'text/html' } }));
  await assert.rejects(gateway.api.get('/shipments'), (error) => error.code === 'unexpected_response' && error.status === 502);

  const liar = setup(() => jsonResponse(200, { unexpected: true }));
  await assert.rejects(liar.api.get('/shipments'), (error) => error.code === 'unexpected_response');

  const broken = setup(() => new Response('{not json', { status: 200, headers: { 'Content-Type': 'application/json' } }));
  await assert.rejects(broken.api.get('/shipments'), (error) => error.code === 'unexpected_response');
});

test('aborted requests surface as AbortError, not as ApiError', async () => {
  const { api } = setup(() => {
    throw new DOMException('aborted', 'AbortError');
  });
  await assert.rejects(api.get('/shipments'), (error) => isAbortError(error) && !(error instanceof ApiError));
});

test('renews an expired access token once and retries the request', async () => {
  let refreshed = false;
  const { api, calls, session, ended } = setup((request) => {
    if (request.path === '/api/v1/auth/refresh') {
      refreshed = true;
      assert.deepEqual(request.body, { refresh_token: 'refresh-token-1-padding-padding' });
      assert.equal('Authorization' in request.headers, false);
      return ok(authSession('2'));
    }
    return refreshed && request.headers.Authorization === 'Bearer access-2'
      ? ok({ items: [] })
      : fail(401, 'token_expired', 'توکن منقضی شده است.');
  });
  const result = await api.get('/shipments');
  assert.deepEqual(result.data, { items: [] });
  assert.deepEqual(calls.map((call) => call.path), ['/api/v1/shipments', '/api/v1/auth/refresh', '/api/v1/shipments']);
  assert.equal(session.read().accessToken, 'access-2');
  assert.equal(session.read().refreshToken, 'refresh-token-2-padding-padding');
  assert.deepEqual(ended, []);
});

test('renews proactively when the token is about to expire', async () => {
  const { api, calls, now } = setup((request) => (request.path.endsWith('/auth/refresh') ? ok(authSession('2')) : ok({ fine: true })));
  now.advance(900_000 - 10_000); // ten seconds left
  await api.get('/dashboard/summary');
  assert.deepEqual(calls.map((call) => call.path), ['/api/v1/auth/refresh', '/api/v1/dashboard/summary']);
  assert.equal(calls[1].headers.Authorization, 'Bearer access-2');
});

test('concurrent requests share a single refresh (refresh tokens are single-use)', async () => {
  let refreshCalls = 0;
  const { api, calls, now } = setup(async (request) => {
    if (request.path.endsWith('/auth/refresh')) {
      refreshCalls += 1;
      await new Promise((resolve) => setTimeout(resolve, 10));
      return ok(authSession('2'));
    }
    return request.headers.Authorization === 'Bearer access-2' ? ok({ path: request.path }) : fail(401, 'token_expired');
  });
  now.advance(900_000); // expired locally: all five requests need a renewal first
  const results = await Promise.all(['/a', '/b', '/c', '/d', '/e'].map((path) => api.get(path)));
  assert.equal(refreshCalls, 1);
  assert.deepEqual(results.map((result) => result.data.path), ['/api/v1/a', '/api/v1/b', '/api/v1/c', '/api/v1/d', '/api/v1/e']);
  assert.equal(calls.filter((call) => !call.path.endsWith('/auth/refresh')).every((call) => call.headers.Authorization === 'Bearer access-2'), true);
});

test('a second refresh happens when the renewed token expires again later', async () => {
  let generation = 1;
  const { api, calls, now } = setup((request) => {
    if (request.path.endsWith('/auth/refresh')) {
      generation += 1;
      return ok(authSession(String(generation)));
    }
    return ok({});
  });
  now.advance(900_000);
  await api.get('/a');
  now.advance(900_000);
  await api.get('/b');
  assert.equal(calls.filter((call) => call.path.endsWith('/auth/refresh')).length, 2);
  assert.equal(calls.at(-1).headers.Authorization, 'Bearer access-3');
});

test('tabs coordinate through Web Locks: the second tab reuses the first renewal', async () => {
  const storage = createMemoryStorage();
  const now = clock();
  const locks = fakeLocks();
  let refreshCalls = 0;
  const handler = async (request) => {
    if (request.path.endsWith('/auth/refresh')) {
      refreshCalls += 1;
      // A rotated token must never be presented twice: the server would revoke the whole session.
      assert.equal(request.body.refresh_token, 'refresh-token-1-padding-padding');
      await new Promise((resolve) => setTimeout(resolve, 10));
      return ok(authSession('2'));
    }
    return ok({ token: request.headers.Authorization });
  };
  const tabA = setup(handler, { storage, now, locks });
  const tabB = setup(handler, { storage, now, locks });
  now.advance(900_000);
  const [a, b] = await Promise.all([tabA.api.get('/x'), tabB.api.get('/y')]);
  assert.equal(refreshCalls, 1);
  assert.equal(locks.requests, 2);
  assert.equal(a.data.token, 'Bearer access-2');
  assert.equal(b.data.token, 'Bearer access-2');
});

test('ends the session when the refresh token is rejected', async () => {
  const { api, session, ended, calls } = setup((request) =>
    request.path.endsWith('/auth/refresh')
      ? fail(401, 'refresh_token_invalid', 'نشست معتبر نیست.')
      : fail(401, 'token_expired', 'توکن منقضی شده است.'),
  );
  await assert.rejects(api.get('/shipments'), (error) => {
    assert.equal(error.status, 401);
    assert.equal(error.code, 'refresh_token_invalid');
    assert.match(error.message, /دوباره وارد شوید/);
    return true;
  });
  assert.equal(session.read(), null);
  assert.equal(ended.length, 1);
  assert.equal(calls.length, 2); // the original request is not retried
});

test('keeps the session when the refresh fails for a transient reason', async () => {
  for (const transient of [
    () => {
      throw new TypeError('offline');
    },
    () => fail(429, 'rate_limited', 'بعداً تلاش کنید.', { retry_after_seconds: 5 }),
    () => fail(503, 'service_unavailable', 'سرویس در دسترس نیست.'),
  ]) {
    const { api, session, ended } = setup((request) => (request.path.endsWith('/auth/refresh') ? transient() : fail(401, 'token_expired')));
    await assert.rejects(api.get('/shipments'), ApiError);
    assert.notEqual(session.read(), null);
    assert.deepEqual(ended, []);
  }
});

test('ends the session for revoked tokens and disabled accounts without trying to refresh', async () => {
  for (const code of ['token_revoked', 'token_invalid', 'account_disabled', 'company_inactive', 'authentication_required']) {
    const { api, session, ended, calls } = setup(() => fail(401, code, 'دسترسی ندارید.'));
    await assert.rejects(api.get('/shipments'), (error) => error.code === code);
    assert.equal(session.read(), null, code);
    assert.equal(ended.length, 1);
    assert.equal(calls.length, 1);
  }
});

test('ends the session when the renewed token is rejected as well', async () => {
  const { api, session, ended, calls } = setup((request) =>
    request.path.endsWith('/auth/refresh') ? ok(authSession('2')) : fail(401, 'token_expired'),
  );
  await assert.rejects(api.get('/shipments'), (error) => error.code === 'token_expired');
  assert.equal(calls.length, 3); // exactly one retry: no refresh loop
  assert.equal(session.read(), null);
  assert.equal(ended.length, 1);
});

test('authenticated requests without a session fail fast', async () => {
  const { api, calls, ended } = setup(() => ok({}), { loggedIn: false });
  await assert.rejects(api.get('/shipments'), (error) => error.status === 401 && error.code === 'authentication_required');
  assert.equal(calls.length, 0);
  assert.equal(ended.length, 1);
});

test('login stores the session; a failed login does not', async () => {
  const good = setup((request) => {
    assert.deepEqual(request.body, { username: 'admin', password: 'secret-password' });
    assert.equal('Authorization' in request.headers, false);
    return ok(authSession('9'), 'خوش آمدید.');
  }, { loggedIn: false });
  const result = await good.api.login('admin', 'secret-password');
  assert.equal(result.message, 'خوش آمدید.');
  assert.equal(good.session.read().accessToken, 'access-9');

  const bad = setup(() => fail(401, 'invalid_credentials', 'نام کاربری یا رمز عبور نادرست است.'), { loggedIn: false });
  await assert.rejects(bad.api.login('admin', 'wrong'), (error) => error.code === 'invalid_credentials');
  assert.equal(bad.session.read(), null);
  assert.deepEqual(bad.ended, []); // a wrong password is not an "ended session"
});

test('logout always clears the local session', async () => {
  const normal = setup(() => ok(null, 'خارج شدید.'));
  await normal.api.logout();
  assert.equal(normal.session.read(), null);
  assert.equal(normal.calls[0].path, '/api/v1/auth/logout');

  const offline = setup(() => {
    throw new TypeError('offline');
  });
  await offline.api.logout();
  assert.equal(offline.session.read(), null);

  const anonymous = setup(() => ok(null), { loggedIn: false });
  await anonymous.api.logout();
  assert.equal(anonymous.calls.length, 0);
});

test('change-password replaces the tokens and refreshProfile updates permissions', async () => {
  const { api, session } = setup((request) => {
    if (request.path.endsWith('/auth/change-password')) {
      assert.deepEqual(request.body, { current_password: 'old-password', new_password: 'new-password-1' });
      return ok(authSession('5'), 'رمز عبور تغییر کرد.');
    }
    return ok({ user: { ...authSession().user, full_name: 'نام جدید' }, permissions: ['shipment:view', 'document:delete'] });
  });
  await api.changePassword('old-password', 'new-password-1');
  assert.equal(session.read().refreshToken, 'refresh-token-5-padding-padding');
  const profile = await api.refreshProfile();
  assert.equal(profile.user.full_name, 'نام جدید');
  assert.equal(session.can('document:delete'), true);
});

test('downloads files with their server-provided names', async () => {
  const { api, calls } = setup(
    () =>
      new Response(new Blob(['%PDF-1.7']), {
        status: 200,
        headers: {
          'Content-Type': 'application/pdf',
          'Content-Disposition': "attachment; filename=barnameh.pdf; filename*=UTF-8''%D8%A8%D8%A7%D8%B1%D9%86%D8%A7%D9%85%D9%87.pdf",
        },
      }),
  );
  const file = await api.download('/documents/d1/download');
  assert.equal(file.filename, 'بارنامه.pdf');
  assert.equal(file.contentType, 'application/pdf');
  assert.equal(await file.blob.text(), '%PDF-1.7');
  assert.equal(calls[0].headers.Authorization, 'Bearer access-1');

  const customer = setup(() => fail(404, 'document_not_found', 'سند در دسترس نیست.'), { loggedIn: false });
  await assert.rejects(customer.api.download('/customer/access/token/documents/d1/download', { auth: false }), (error) => error.isNotFound);
});

test('parses Content-Disposition file names', () => {
  assert.equal(filenameFromContentDisposition('attachment; filename="report 1.pdf"'), 'report 1.pdf');
  assert.equal(filenameFromContentDisposition('attachment; filename=plain.txt'), 'plain.txt');
  assert.equal(filenameFromContentDisposition('attachment; filename="a \\"quoted\\" name.pdf"'), 'a "quoted" name.pdf');
  assert.equal(filenameFromContentDisposition("attachment; filename*=UTF-8''%D8%B3%D9%86%D8%AF.pdf"), 'سند.pdf');
  assert.equal(filenameFromContentDisposition("attachment; filename=fallback.pdf; filename*=UTF-8''%E0%A4%A"), 'fallback.pdf');
  assert.equal(filenameFromContentDisposition(null), 'download');
  assert.equal(filenameFromContentDisposition('attachment'), 'download');
  assert.equal(filenameFromContentDisposition('', 'سند'), 'سند');
});
