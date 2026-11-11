/** Page chrome: the public layout (customer portal, login) and the staff shell with its navigation. */

import { h, icon, ltr } from '../core/dom.js';
import { roleLabel } from './table.js';

export const APP_NAME = 'حمل‌ونقل ';

function brand(href) {
  return h('a', { class: 'brand', href }, h('span', { class: 'brand-mark' }, icon('truck', { size: 22 })), h('span', {}, APP_NAME));
}

/** Layout for visitors who are not signed in. `headerLink` is `{ href, label, iconName }`. */
export function publicLayout({ content, headerLink = null, narrow = false }) {
  return h(
    'div',
    { class: 'public' },
    h(
      'header',
      { class: 'public-header' },
      brand('#/track'),
      headerLink && h('a', { class: 'btn btn-secondary btn-sm', href: headerLink.href }, icon(headerLink.iconName, { size: 16 }), headerLink.label),
    ),
    h('main', { class: `public-main ${narrow ? 'narrow' : ''}`.trim(), id: 'main' }, content),
    h('footer', { class: 'public-footer' }, `© ${APP_NAME}`),
  );
}

/**
 * The signed-in shell. It stays mounted while the user navigates; only the content
 * area is replaced. Returns `{ element, setPage({ title, element, activePath }), refreshUser() }`.
 */
export function createShell({ session, navItems, onLogout }) {
  const title = h('div', { class: 'topbar-title' });
  const content = h('main', { class: 'content', id: 'main', tabindex: '-1' });
  const nav = h('ul', { class: 'nav' });
  const userName = h('strong', {});
  const userMeta = h('span', {});
  const shell = h('div', { class: 'shell' });

  const toggle = h(
    'button',
    { type: 'button', class: 'btn btn-ghost btn-icon menu-toggle', 'aria-label': 'فهرست اصلی', 'aria-expanded': 'false', 'aria-controls': 'main-navigation' },
    icon('menu', { size: 20 }),
  );
  // On narrow screens the navigation is a drawer. Opening it moves the focus into it; dismissing it gives the focus back.
  const isNavOpen = () => shell.classList.contains('nav-open');
  const setNavOpen = (open) => {
    shell.classList.toggle('nav-open', open);
    toggle.setAttribute('aria-expanded', String(open));
  };
  const closeNav = () => setNavOpen(false);
  const dismissNav = () => {
    if (!isNavOpen()) return;
    closeNav();
    toggle.focus();
  };
  toggle.addEventListener('click', () => {
    setNavOpen(!isNavOpen());
    if (isNavOpen()) (nav.querySelector('[aria-current="page"]') ?? nav.querySelector('a'))?.focus();
  });
  // On phones only the icons are shown, so the names are given explicitly.
  const logout = h(
    'button',
    { type: 'button', class: 'btn btn-ghost btn-sm', 'aria-label': 'خروج', title: 'خروج', onClick: onLogout },
    icon('logout', { size: 16 }),
    h('span', { class: 'hide-mobile' }, 'خروج'),
  );
  const profile = h(
    'a',
    { class: 'btn btn-ghost btn-sm', href: '#/profile', 'aria-label': 'حساب کاربری', title: 'حساب کاربری' },
    icon('user', { size: 16 }),
    h('span', { class: 'hide-mobile' }, 'حساب کاربری'),
  );

  function renderNav(activePath) {
    nav.replaceChildren(
      ...navItems
        .filter((item) => session.can(item.permission))
        .map((item) =>
          h(
            'li',
            {},
            h(
              'a',
              { class: 'nav-link', href: `#${item.path}`, 'aria-current': activePath === item.path ? 'page' : null, onClick: closeNav },
              icon(item.icon),
              h('span', {}, item.label),
            ),
          ),
        ),
    );
  }

  function refreshUser() {
    const user = session.user;
    userName.textContent = user?.full_name ?? '';
    userMeta.replaceChildren(
      roleLabel(user?.role),
      user?.company?.name ? ` · ${user.company.name}` : '',
      h('br'),
      ltr(user?.username ?? '', 'code'),
    );
  }

  shell.append(
    h('aside', { class: 'sidebar', id: 'main-navigation', 'aria-label': 'فهرست اصلی' }, brand('#/dashboard'), h('nav', {}, nav), h('div', { class: 'sidebar-footer' }, userName, userMeta)),
    h('button', { type: 'button', class: 'backdrop', 'aria-label': 'بستن فهرست', tabindex: '-1', onClick: dismissNav }),
    h('div', { class: 'main' }, h('header', { class: 'topbar' }, toggle, title, profile, logout), content),
  );
  shell.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') dismissNav();
  });
  refreshUser();

  return {
    element: shell,
    refreshUser,
    setPage({ title: pageTitle, element, activePath }) {
      closeNav();
      title.textContent = pageTitle;
      renderNav(activePath);
      content.replaceChildren(element);
      content.scrollTop = 0;
      window.scrollTo(0, 0);
    },
  };
}

/** Standard page heading with optional description and action buttons. */
export function pageHeader({ title, description = null, actions = [] }) {
  return h(
    'div',
    { class: 'page-header' },
    h('div', {}, h('h1', {}, title), description && h('p', {}, description)),
    actions.length > 0 && h('div', { class: 'row' }, actions),
  );
}
