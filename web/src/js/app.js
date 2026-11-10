/** Application bootstrap: wires the session, the API client and the hash router to the DOM. */

import { config } from './config.js';
import { createApiClient, isAbortError } from './core/api.js';
import { h, mount } from './core/dom.js';
import { buildHash, createRouteTable, parseHash, resolveAccess } from './core/router.js';
import { createMemoryStorage, createSessionStore } from './core/session.js';
import { NAV_ITEMS, ROUTES } from './routes.js';
import { emptyBlock, errorBlock, errorMessage, toast } from './ui/feedback.js';
import { APP_NAME, createShell, publicLayout } from './ui/layout.js';

function browserStorage() {
  try {
    const probe = '__armin_probe__';
    window.localStorage.setItem(probe, '1');
    window.localStorage.removeItem(probe);
    return window.localStorage;
  } catch {
    return createMemoryStorage(); // storage blocked: the session lasts until the tab is reloaded
  }
}

export function startApp(root) {
  const session = createSessionStore({ storage: browserStorage() });
  const table = createRouteTable(ROUTES);
  let shell = null;
  let pageAbort = null;
  let renderedHash = null;
  let lastSessionEndedToast = 0;

  const api = createApiClient({
    baseUrl: config.apiBaseUrl,
    session,
    fetchImpl: (url, init) => window.fetch(url, init),
    locks: navigator.locks ?? null,
    onSessionEnded(error) {
      const now = Date.now();
      if (now - lastSessionEndedToast > 3000) toast.error(errorMessage(error));
      lastSessionEndedToast = now;
    },
  });

  function navigate(hash, { replace = false } = {}) {
    if (hash === window.location.hash) {
      render();
    } else if (replace) {
      window.location.replace(hash);
    } else {
      window.location.hash = hash;
    }
  }

  async function logout() {
    await api.logout();
    toast.info('از حساب کاربری خود خارج شدید.');
    navigate('#/login');
  }

  function ensureShell() {
    if (shell === null) {
      shell = createShell({ session, navItems: NAV_ITEMS, onLogout: logout });
      mount(root, shell.element);
    }
    return shell;
  }

  function showPage(route, page, path) {
    document.title = `${page.title} | ${APP_NAME}`;
    if (route.layout === 'public') {
      shell = null;
      mount(root, publicLayout({ content: page.element, headerLink: page.headerLink ?? null, narrow: Boolean(route.narrow) }));
      window.scrollTo(0, 0);
    } else {
      ensureShell().setPage({ title: page.title, element: page.element, activePath: route.navPath ?? path });
    }
  }

  function render() {
    pageAbort?.abort();
    pageAbort = new AbortController();
    renderedHash = window.location.hash;
    // A dialog belongs to the page that opened it; it must not survive a navigation or the end of the session.
    for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close();
    const { path, query } = parseHash(window.location.hash);
    const isAuthenticated = session.isAuthenticated();

    if (path === '/') {
      navigate(isAuthenticated ? '#/dashboard' : '#/track', { replace: true });
      return;
    }

    const match = table.match(path);
    if (match === null) {
      const notFound = {
        title: 'صفحه یافت نشد',
        element: emptyBlock({
          iconName: 'alert',
          title: 'صفحهٔ موردنظر یافت نشد.',
          action: h('a', { class: 'btn', href: isAuthenticated ? '#/dashboard' : '#/track' }, 'بازگشت به صفحهٔ اصلی'),
        }),
      };
      showPage(isAuthenticated ? { navPath: null } : { layout: 'public' }, notFound, path);
      return;
    }

    const { route, params } = match;
    const access = resolveAccess(route, { isAuthenticated, can: (permission) => session.can(permission), currentHash: window.location.hash });
    if (access.action === 'redirect') {
      navigate(access.to, { replace: true });
      return;
    }
    if (access.action === 'forbidden') {
      showPage(
        { navPath: null },
        { title: 'عدم دسترسی', element: emptyBlock({ iconName: 'lock', title: 'شما اجازهٔ مشاهدهٔ این صفحه را ندارید.' }) },
        path,
      );
      return;
    }

    const context = {
      api,
      session,
      params,
      query,
      path,
      signal: pageAbort.signal,
      navigate,
      /** Re-renders the current page (after a change that affects what it shows). */
      reload: render,
      /** Updates the query part of the location; `null` values remove a parameter. */
      setQuery(patch, { replace = false } = {}) {
        navigate(buildHash(path, { ...query, ...patch }), { replace });
      },
      /** The query as it is in the address right now (it may have been changed by `rememberQuery`). */
      liveQuery: () => parseHash(window.location.hash).query,
      /** Records view state (such as the selected tab) in the address without re-rendering the page. */
      rememberQuery(patch) {
        window.history.replaceState(null, '', buildHash(path, { ...parseHash(window.location.hash).query, ...patch }));
        renderedHash = window.location.hash;
      },
    };
    try {
      showPage(route, route.page(context), path);
    } catch (error) {
      if (!isAbortError(error)) showPage(route, { title: 'خطا', element: errorBlock(error, render) }, path);
    }
  }

  // Re-render when the signed-in user changes (login, logout or session end, also in another tab).
  let knownUserId = session.isAuthenticated() ? (session.user?.id ?? null) : null;
  session.subscribe(() => {
    const userId = session.isAuthenticated() ? (session.user?.id ?? null) : null;
    if (userId !== knownUserId) {
      knownUserId = userId;
      shell = null;
      render();
    } else {
      shell?.refreshUser();
    }
  });

  window.addEventListener('hashchange', () => {
    // navigate() renders at once when the address is already current; skip the echo of that change.
    if (window.location.hash !== renderedHash) render();
  });
  window.addEventListener('storage', (event) => session.handleStorageEvent(event));
  render();

  // Permissions may have changed since the last visit; refresh them in the background.
  if (session.isAuthenticated()) {
    api.refreshProfile().catch(() => {
      // Failures are reported by the page that needs the data; a dead session redirects to the login page.
    });
  }
}
