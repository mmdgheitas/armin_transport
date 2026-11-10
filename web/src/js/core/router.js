/**
 * Hash-based routing primitives (pure functions; the DOM wiring lives in app.js).
 *
 * Locations look like "#/shipments/42?status=ACTIVE&page=2". Hash routing keeps the
 * client deployable on any static host without server-side rewrite rules.
 */

/** Compiles "/shipments/:id" into a matcher. */
function compile(pattern) {
  const names = [];
  const source = pattern
    .split('/')
    .map((segment) => {
      if (segment.startsWith(':')) {
        names.push(segment.slice(1));
        return '([^/]+)';
      }
      return segment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    })
    .join('/');
  return { regex: new RegExp(`^${source}/?$`), names };
}

function safeDecode(text) {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

/** Parses a location hash into `{ path, query }`; an empty hash is the root path "/". */
export function parseHash(hash) {
  const raw = String(hash ?? '').replace(/^#/, '');
  const [pathPart, queryPart = ''] = raw.split('?', 2);
  let path = pathPart || '/';
  if (!path.startsWith('/')) path = `/${path}`;
  if (path.length > 1) path = path.replace(/\/+$/, '');
  const query = {};
  for (const [key, value] of new URLSearchParams(queryPart)) query[key] = value;
  return { path, query };
}

/** Builds a hash from a path and a query object; empty, null and undefined values are omitted. */
export function buildHash(path, query = {}) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value !== null && value !== undefined && value !== '') params.set(key, String(value));
  }
  const text = params.toString();
  return `#${path}${text ? `?${text}` : ''}`;
}

export function createRouteTable(routes) {
  const compiled = routes.map((route) => ({ route, ...compile(route.path) }));
  return {
    /** Returns `{ route, params }` for the first route matching `path`, or `null`. */
    match(path) {
      for (const { route, regex, names } of compiled) {
        const found = regex.exec(path);
        if (found) {
          const params = {};
          names.forEach((name, index) => {
            params[name] = safeDecode(found[index + 1]);
          });
          return { route, params };
        }
      }
      return null;
    },
  };
}

/**
 * Decides what to do with a matched route for the current visitor.
 * Returns `{ action: 'render' }`, `{ action: 'redirect', to }` or `{ action: 'forbidden' }`.
 */
export function resolveAccess(route, { isAuthenticated, can, currentHash = '' }) {
  if (route.guestOnly && isAuthenticated) return { action: 'redirect', to: '#/dashboard' };
  if (route.auth && !isAuthenticated) {
    const next = currentHash && currentHash !== '#/' ? currentHash : '';
    return { action: 'redirect', to: buildHash('/login', next ? { next } : {}) };
  }
  if (route.permission && !can(route.permission)) return { action: 'forbidden' };
  return { action: 'render' };
}

/** Only in-app hashes are accepted as post-login destinations (never external URLs). */
export function safeNextHash(next, fallback = '#/dashboard') {
  return typeof next === 'string' && /^#\/[^/\\]/.test(next) && !next.startsWith('#/login') ? next : fallback;
}
