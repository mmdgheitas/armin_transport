/**
 * HTTP client for the Armin Transport API.
 *
 * - Understands the response envelope `{ success, message, data, errors }`.
 * - Attaches the access token and transparently renews it. Refresh tokens rotate
 *   and reuse revokes the whole session, so renewal is single-flight: one request
 *   per tab (shared promise) and one per browser (Web Locks) at any time.
 * - Reports every failure as an `ApiError` with a Persian, user-presentable message.
 */

/** Renew the access token this long before it expires, so requests are not sent with a dying token. */
const EXPIRY_SKEW_MS = 20_000;
const REFRESH_LOCK_NAME = 'armin-transport.auth.refresh';

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

export function createApiClient({ baseUrl, session, fetchImpl, locks = null, now = () => Date.now(), onSessionEnded = () => {} }) {
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

  function runExclusive(task) {
    return locks && typeof locks.request === 'function' ? locks.request(REFRESH_LOCK_NAME, task) : task();
  }

  /** Renews the tokens once, no matter how many requests ask at the same time. Resolves to the new access token. */
  function refreshAccessToken() {
    if (refreshInFlight === null) {
      const seenRefreshToken = session.read()?.refreshToken ?? null;
      refreshInFlight = runExclusive(async () => {
        const current = session.read();
        if (current === null) throw new ApiError({ status: 401, code: 'authentication_required', message: SESSION_ENDED_MESSAGE });
        // Another tab renewed the session while this one waited for the lock: use its result.
        if (current.refreshToken !== seenRefreshToken && current.accessExpiresAt - now() > EXPIRY_SKEW_MS) {
          return current.accessToken;
        }
        const response = await send('POST', '/auth/refresh', { json: { refresh_token: current.refreshToken } });
        if (!response.ok) throw await toApiError(response);
        const envelope = await readEnvelope(response);
        if (!envelope?.data?.access_token) throw new ApiError({ status: response.status, code: 'unexpected_response' });
        session.setFromAuthResponse(envelope.data);
        return envelope.data.access_token;
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
