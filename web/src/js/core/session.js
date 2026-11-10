/**
 * Staff session state: tokens, profile and permissions.
 *
 * The session lives in localStorage so that all tabs share one login and one
 * refresh-token chain. The trade-off (tokens are readable by scripts of this
 * origin) is mitigated by a strict Content-Security-Policy and by never
 * rendering untrusted markup; see docs/SECURITY.md.
 */

export const SESSION_STORAGE_KEY = 'armin-transport.session.v1';

function isValidSession(value) {
  return (
    value !== null &&
    typeof value === 'object' &&
    typeof value.accessToken === 'string' &&
    typeof value.refreshToken === 'string' &&
    typeof value.accessExpiresAt === 'number' &&
    typeof value.refreshExpiresAt === 'number' &&
    value.user !== null &&
    typeof value.user === 'object' &&
    Array.isArray(value.permissions)
  );
}

export function createSessionStore({ storage, now = () => Date.now() }) {
  const listeners = new Set();

  function read() {
    try {
      const parsed = JSON.parse(storage.getItem(SESSION_STORAGE_KEY) ?? 'null');
      return isValidSession(parsed) ? parsed : null;
    } catch {
      return null;
    }
  }

  function notify() {
    const session = read();
    for (const listener of listeners) listener(session);
  }

  function write(session) {
    try {
      storage.setItem(SESSION_STORAGE_KEY, JSON.stringify(session));
    } catch {
      // Storage may be unavailable (private mode, quota). The session then lasts until the next reload.
    }
    notify();
  }

  return {
    /** The stored session or `null`; always read from storage so changes made by other tabs are seen. */
    read,

    isAuthenticated() {
      const session = read();
      return session !== null && session.refreshExpiresAt > now();
    },

    get user() {
      return read()?.user ?? null;
    },

    get appSettings() {
      return read()?.appSettings ?? {};
    },

    can(permission) {
      return read()?.permissions.includes(permission) ?? false;
    },

    get isGlobalScope() {
      return this.can('scope:global');
    },

    /** Stores the result of login, refresh or change-password (`AuthSession` in the API). */
    setFromAuthResponse(data) {
      const issuedAt = now();
      write({
        accessToken: data.access_token,
        refreshToken: data.refresh_token,
        accessExpiresAt: issuedAt + data.expires_in * 1000,
        refreshExpiresAt: issuedAt + data.refresh_expires_in * 1000,
        user: data.user,
        permissions: data.permissions ?? [],
        appSettings: data.app_settings ?? {},
      });
    },

    /** Applies a fresh profile (`GET /auth/me`) without touching the tokens. */
    updateProfile(profile) {
      const session = read();
      if (!session) return;
      write({
        ...session,
        user: profile.user,
        permissions: profile.permissions ?? [],
        appSettings: profile.app_settings ?? session.appSettings,
      });
    },

    clear() {
      try {
        storage.removeItem(SESSION_STORAGE_KEY);
      } catch {
        // Nothing to clean up when storage is unavailable.
      }
      notify();
    },

    /** Calls `listener(session | null)` after every change made through this store. */
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },

    /** Forwards a window "storage" event so listeners learn about changes made by other tabs. */
    handleStorageEvent(event) {
      if (event.key === null || event.key === SESSION_STORAGE_KEY) notify();
    },
  };
}

/** In-memory stand-in for localStorage (tests, and browsers where storage is blocked). */
export function createMemoryStorage() {
  const values = new Map();
  return {
    getItem: (key) => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}
