/** Test doubles shared by the unit tests. */

export function jsonResponse(status, body, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
}

export function ok(data, message = 'انجام شد.', status = 200) {
  return jsonResponse(status, { success: true, message, data, errors: null });
}

export function fail(status, code, message = 'خطا', extra = {}) {
  return jsonResponse(status, { success: false, message, data: null, errors: { code, request_id: 'req-test-0001', ...extra } });
}

export function authSession(suffix = '1', overrides = {}) {
  return {
    access_token: `access-${suffix}`,
    refresh_token: `refresh-token-${suffix}-padding-padding`,
    token_type: 'Bearer',
    expires_in: 900,
    refresh_expires_in: 1_209_600,
    user: { id: 'u1', username: 'armin.operator', full_name: 'سارا محمدی', role: 'EMPLOYEE', company_id: 'c1' },
    permissions: ['dashboard:view', 'shipment:view'],
    app_settings: { password: { min_length: 10 } },
    ...overrides,
  };
}

/**
 * A scripted `fetch`: `handler(request)` receives `{ method, url, path, headers, body }`
 * and returns a Response (or throws). Every call is recorded in `calls`.
 */
export function fakeFetch(handler) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    const parsed = new URL(url, 'http://test.local');
    const request = {
      method: init.method ?? 'GET',
      url,
      path: parsed.pathname,
      query: Object.fromEntries(parsed.searchParams),
      headers: init.headers ?? {},
      body: typeof init.body === 'string' ? JSON.parse(init.body) : init.body,
      init,
    };
    calls.push(request);
    return handler(request);
  };
  return { fetchImpl, calls };
}

/** A Web Locks stand-in that runs tasks one at a time, like `navigator.locks.request`. */
export function fakeLocks() {
  let tail = Promise.resolve();
  return {
    requests: 0,
    request(_name, task) {
      this.requests += 1;
      const run = tail.then(() => task());
      tail = run.catch(() => {});
      return run;
    },
  };
}

export function clock(start = 1_800_000_000_000) {
  const state = { now: start };
  const now = () => state.now;
  now.advance = (milliseconds) => {
    state.now += milliseconds;
  };
  return now;
}
