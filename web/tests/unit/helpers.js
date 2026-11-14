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

/**
 * A Web Locks stand-in with one holder at a time, like `navigator.locks.request`:
 * with `{ ifAvailable: true }` a taken lock answers `task(null)` instead of waiting.
 */
export function fakeLocks() {
  const waiting = [];
  const locks = {
    held: false,
    requests: 0,
    request(name, optionsOrTask, maybeTask) {
      const task = typeof optionsOrTask === 'function' ? optionsOrTask : maybeTask;
      const ifAvailable = typeof optionsOrTask === 'object' && optionsOrTask.ifAvailable === true;
      locks.requests += 1;
      if (locks.held && ifAvailable) return Promise.resolve().then(() => task(null));
      return new Promise((resolve, reject) => {
        const run = () => {
          locks.held = true;
          Promise.resolve()
            .then(() => task({ name }))
            .then(resolve, reject)
            .finally(() => {
              locks.held = false;
              waiting.shift()?.();
            });
        };
        if (locks.held) waiting.push(run);
        else run();
      });
    },
  };
  return locks;
}

/** A `delay(ms)` that waits until the test lets it go: `pending` lists the waits, `release()` ends them all. */
export function manualDelay() {
  const waits = [];
  const delay = (milliseconds) => new Promise((resolve) => waits.push({ milliseconds, resolve }));
  Object.defineProperty(delay, 'pending', { get: () => waits.map((wait) => wait.milliseconds) });
  delay.release = () => {
    for (const wait of waits.splice(0)) wait.resolve();
  };
  return delay;
}

/** Lets everything that is ready to run (promise reactions, immediates) run. */
export function settle() {
  return new Promise((resolve) => setImmediate(resolve));
}

/**
 * The view that another tab has of a shared storage: it reads what was there at the last `sync()`,
 * the way a browser tab sees the writes of other tabs only a moment later.
 */
export function laggingStorage(storage, keys) {
  const seen = new Map();
  const view = {
    getItem: (key) => (seen.has(key) ? seen.get(key) : null),
    setItem(key, value) {
      storage.setItem(key, value);
      seen.set(key, String(value));
    },
    removeItem(key) {
      storage.removeItem(key);
      seen.delete(key);
    },
    sync() {
      for (const key of keys) {
        const value = storage.getItem(key);
        if (value === null) seen.delete(key);
        else seen.set(key, value);
      }
    },
  };
  view.sync();
  return view;
}

export function clock(start = 1_800_000_000_000) {
  const state = { now: start };
  const now = () => state.now;
  now.advance = (milliseconds) => {
    state.now += milliseconds;
  };
  return now;
}
