/**
 * HTTP client for the Armin Transport API.
 *
 * - Understands the response envelope `{ success, message, data, errors }`.
 * - Attaches the access token and transparently renews it. Refresh tokens rotate
 *   and reuse revokes the whole session, so renewal is single-flight: one request
 *   per tab (shared promise) and one per browser (a lock shared by all tabs) at any time.
 * - Reports every failure as an `ApiError` with a Persian, user-presentable message.
 */

/** Renew the access token this long before it expires, so requests are not sent with a dying token. */
const EXPIRY_SKEW_MS = 20_000;
const REFRESH_LOCK_NAME = 'armin-transport.auth.refresh';
/**
 * What one tab stores reaches the other tabs a moment later, and not in step with the lock:
 * a tab can be given the lock before it sees the session that the previous holder stored.
 * So the tab that renewed keeps the lock a little longer than it needs it ...
 */
const STORAGE_SETTLE_MS = 150;
/** ... and a tab that had to wait for the lock waits at most this long for the renewed session to arrive. */
const STORAGE_CATCH_UP_MS = 1000;

const NETWORK_MESSAGE = 'ارتباط با سرور برقرار نشد. اتصال اینترنت خود را بررسی و دوباره تلاش کنید.';
const UNEXPECTED_MESSAGE = 'پاسخ نامعتبری از سرور دریافت شد. لطفاً دوباره تلاش کنید.';
const SESSION_ENDED_MESSAGE = 'نشست شما به پایان رسیده است. لطفاً دوباره وارد شوید.';

export class ApiError extends Error {
  constructor({ status = 0, code = 'unknown_error', message = UNEXPECTED_MESSAGE, errors = {} } = {}) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    /** Per-field validation messages: `{ field_name: [message, ...] }`. */
    this.fields = errors.fields && typeof errors.fields === 'object' ? errors.fields : {};
    this.requestId = errors.request_id ?? null;
    this.retryAfterSeconds = errors.retry_after_seconds ?? null;
    this.requiredPermissions = errors.required_permissions ?? [];
    this.details = errors;
  }

  get isNetworkError() {
    return this.code === 'network_error';
  }

  get isValidation() {
    return this.status === 422;
  }

  get isNotFound() {
    return this.status === 404;
  }
}

export function isAbortError(error) {
  return error instanceof Error && error.name === 'AbortError';
}

/** Extracts the file name from a Content-Disposition header (RFC 6266 / RFC 5987). */
export function filenameFromContentDisposition(header, fallback = 'download') {
  if (!header) return fallback;
  const extended = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)/.exec(header);
  if (extended) {
    try {
      return decodeURIComponent(extended[1].trim()) || fallback;
    } catch {
      // Fall through to the plain parameter.
    }
  }
  const quoted = /filename\s*=\s*"((?:[^"\\]|\\.)*)"/.exec(header);
  if (quoted) return quoted[1].replace(/\\(.)/g, '$1') || fallback;
  const plain = /filename\s*=\s*([^;]+)/.exec(header);
  return plain ? plain[1].trim() || fallback : fallback;
}

function buildUrl(baseUrl, path, query) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query ?? {})) {
    if (value !== null && value !== undefined && value !== '') params.set(key, String(value));
  }
  const text = params.toString();
  return `${baseUrl.replace(/\/+$/, '')}${path}${text ? `?${text}` : ''}`;
}

async function readEnvelope(response) {
  const contentType = response.headers.get('Content-Type') ?? '';
  if (!contentType.includes('json')) return null;
  try {
    const body = await response.json();
    return body !== null && typeof body === 'object' && typeof body.success === 'boolean' ? body : null;
  } catch {
    return null;
  }
}

async function toApiError(response) {
  const envelope = await readEnvelope(response);
  if (envelope && envelope.success === false) {
    const errors = envelope.errors ?? {};
    return new ApiError({ status: response.status, code: errors.code, message: envelope.message, errors });
  }
  return new ApiError({ status: response.status, code: 'unexpected_response' });
}

const realDelay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

/**
 * `locks` is `navigator.locks` or a stand-in with the same `request()` (see locks.js); without it
 * the client assumes that it is alone. `delay(ms)` resolves after that time (tests pass their own).
 */
export function createApiClient({ baseUrl, session, fetchImpl, locks = null, now = () => Date.now(), delay = realDelay, onSessionEnded = () => {} }) {
  let refreshInFlight = null;

  async function send(method, path, { query, json, formData, signal, token } = {}) {
    const headers = { Accept: 'application/json' };
    let body;
    if (json !== undefined) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(json);
    } else if (formData !== undefined) {
      body = formData; // the browser sets the multipart boundary itself
    }
    if (token) headers.Authorization = `Bearer ${token}`;
    try {
      return await fetchImpl(buildUrl(baseUrl, path, query), { method, headers, body, signal, credentials: 'omit', cache: 'no-store' });
    } catch (error) {
      if (isAbortError(error)) throw error;
      throw new ApiError({ code: 'network_error', message: NETWORK_MESSAGE });
    }
  }

  function endSession(error) {
    session.clear();
    onSessionEnded(error);
  }

  /**
   * Runs `task(waited)` while no other tab runs one. `waited` tells that another tab held the lock first.
   * When the task resolves to `true` it has stored a new session, and the lock is kept until the other tabs have received it.
   */
  async function runExclusive(task) {
    if (locks === null || typeof locks.request !== 'function') {
      await task(false);
      return;
    }
    const hold = async (waited) => {
      if (await task(waited)) await delay(STORAGE_SETTLE_MS);
    };
    const wasFree = await locks.request(REFRESH_LOCK_NAME, { ifAvailable: true }, async (lock) => {
      if (lock === null) return false;
      await hold(false);
      return true;
    });
    if (!wasFree) await locks.request(REFRESH_LOCK_NAME, () => hold(true));
  }

  /** Resolves when the stored session is no longer the one with `refreshToken`, at the latest after STORAGE_CATCH_UP_MS. */
  function sessionChange(refreshToken) {
    return new Promise((resolve) => {
      const unsubscribe = session.subscribe((current) => {
        if (current === null || current.refreshToken !== refreshToken) finish();
      });
      function finish() {
        unsubscribe();
        resolve();
      }
      delay(STORAGE_CATCH_UP_MS).then(finish);
    });
  }

  /** The part of a renewal that runs under the lock. Resolves to `{ token, stored }`. */
  async function renew(seenRefreshToken, waited) {
    let current = session.read();
    // Another tab held the lock, most likely to renew this very session, and what it stored may not have arrived yet.
    // Sending the old refresh token again would look like theft to the server and end the session in every tab.
    if (waited && current !== null && current.refreshToken === seenRefreshToken) {
      await sessionChange(seenRefreshToken);
      current = session.read();
    }
    if (current === null) throw new ApiError({ status: 401, code: 'authentication_required', message: SESSION_ENDED_MESSAGE });
    // Another tab renewed the session while this one waited for the lock: use its result.
    if (current.refreshToken !== seenRefreshToken && current.accessExpiresAt - now() > EXPIRY_SKEW_MS) {
      return { token: current.accessToken, stored: false };
    }
    const response = await send('POST', '/auth/refresh', { json: { refresh_token: current.refreshToken } });
    if (!response.ok) throw await toApiError(response);
    const envelope = await readEnvelope(response);
    if (!envelope?.data?.access_token) throw new ApiError({ status: response.status, code: 'unexpected_response' });
    session.setFromAuthResponse(envelope.data);
    return { token: envelope.data.access_token, stored: true };
  }

  /** Renews the tokens once, no matter how many requests ask at the same time. Resolves to the new access token. */
  function refreshAccessToken() {
    if (refreshInFlight === null) {
      const seenRefreshToken = session.read()?.refreshToken ?? null;
      // The requests of this tab go on as soon as the token is there; the lock may be held a little longer.
      refreshInFlight = new Promise((resolve, reject) => {
        runExclusive(async (waited) => {
          try {
            const { token, stored } = await renew(seenRefreshToken, waited);
            resolve(token);
            return stored;
          } catch (error) {
            reject(error);
            return false;
          }
        }).catch(reject);
      }).finally(() => {
        refreshInFlight = null;
      });
    }
    return refreshInFlight;
  }

  async function renewOrEndSession() {
    try {
      return await refreshAccessToken();
    } catch (error) {
      // Only a definite rejection ends the session; network failures and rate limits are transient.
      if (error instanceof ApiError && (error.status === 401 || error.status === 403 || error.status === 422)) {
        const ended = new ApiError({ status: 401, code: error.code, message: SESSION_ENDED_MESSAGE, errors: error.details });
        endSession(ended);
        throw ended;
      }
      throw error;
    }
  }

  async function accessToken() {
    const current = session.read();
    if (current === null) {
      const error = new ApiError({ status: 401, code: 'authentication_required', message: SESSION_ENDED_MESSAGE });
      endSession(error);
      throw error;
    }
    return current.accessExpiresAt - now() <= EXPIRY_SKEW_MS ? renewOrEndSession() : current.accessToken;
  }

  /** Sends a request with authentication and one transparent retry after a token renewal. */
  async function exchange(method, path, options) {
    if (options.auth === false) return send(method, path, options);
    let token = await accessToken();
    let response = await send(method, path, { ...options, token });
    if (response.status !== 401) return response;

    let error = await toApiError(response);
    if (error.code === 'token_expired') {
      token = await renewOrEndSession();
      response = await send(method, path, { ...options, token });
      if (response.status !== 401) return response;
      error = await toApiError(response);
    }
    endSession(error);
    throw error;
  }

  /**
   * Performs a JSON request and resolves to `{ data, message }` from the envelope.
   * Options: `query`, `json`, `formData`, `signal`, `auth` (default true).
   */
  async function request(method, path, options = {}) {
    const response = await exchange(method, path, options);
    if (!response.ok) throw await toApiError(response);
    const envelope = await readEnvelope(response);
    if (envelope === null || envelope.success !== true) throw new ApiError({ status: response.status, code: 'unexpected_response' });
    return { data: envelope.data, message: envelope.message };
  }

  /** Downloads a file and resolves to `{ blob, filename, contentType }`. */
  async function download(path, options = {}) {
    const response = await exchange('GET', path, options);
    if (!response.ok) throw await toApiError(response);
    return {
      blob: await response.blob(),
      filename: filenameFromContentDisposition(response.headers.get('Content-Disposition')),
      contentType: response.headers.get('Content-Type') ?? 'application/octet-stream',
    };
  }

  return {
    request,
    download,
    get: (path, options) => request('GET', path, options),
    post: (path, options) => request('POST', path, options),
    put: (path, options) => request('PUT', path, options),
    patch: (path, options) => request('PATCH', path, options),
    delete: (path, options) => request('DELETE', path, options),

    async login(username, password) {
      const result = await request('POST', '/auth/login', { auth: false, json: { username, password } });
      session.setFromAuthResponse(result.data);
      return result;
    },

    /** Revokes the session on the server (best effort) and always clears it locally. */
    async logout() {
      try {
        if (session.read() !== null) await request('POST', '/auth/logout');
      } catch {
        // The local session is cleared regardless; the server-side session expires on its own.
      } finally {
        session.clear();
      }
    },

    async changePassword(currentPassword, newPassword) {
      const result = await request('POST', '/auth/change-password', {
        json: { current_password: currentPassword, new_password: newPassword },
      });
      session.setFromAuthResponse(result.data); // every other session of the user was revoked
      return result;
    },

    async refreshProfile(signal) {
      const result = await request('GET', '/auth/me', { signal });
      session.updateProfile(result.data);
      return result.data;
    },
  };
}
