/**
 * Page driver for the end-to-end tests.
 *
 * Controls are found the way a person (or a screen reader) finds them: by role and by
 * visible label or accessible name, never by CSS class. While a modal dialog is open
 * only its content is searched, because the rest of the page is inert.
 *
 * Every session records console errors, uncaught exceptions, Content-Security-Policy
 * violations, failed requests and HTTP error responses. `assertClean()` fails the
 * scenario for each of them that it did not announce beforehand with `expectHttp()`.
 */

import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';

import { apiClient, startBackend } from './backend.mjs';
import { launchBrowser, SCREENSHOT_DIR } from './browser.mjs';

const DEFAULT_TIMEOUT_MS = 10_000;
const POLL_MS = 40;
export const DESKTOP = { width: 1366, height: 900 };
export const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Persian digits for expectations about what the interface shows. */
export function fa(value) {
  return String(value).replace(/\d/g, (digit) => '۰۱۲۳۴۵۶۷۸۹'[Number(digit)]);
}

/**
 * Polls `probe()` until it yields something other than null, undefined or false.
 * `describe` (text or async function) explains the failure when time runs out.
 */
export async function eventually(probe, describe, timeout = DEFAULT_TIMEOUT_MS) {
  const deadline = Date.now() + timeout;
  for (;;) {
    let failure = null;
    try {
      const value = await probe();
      if (value !== null && value !== undefined && value !== false) return value;
    } catch (error) {
      failure = error; // typically a navigation destroyed the execution context; the next attempt sees the new page
    }
    if (Date.now() >= deadline) {
      const reason = typeof describe === 'function' ? await describe() : describe;
      throw new Error(`${reason} (waited ${timeout} ms)${failure ? `; last error: ${failure.message}` : ''}`);
    }
    await sleep(POLL_MS);
  }
}

/** Installed in every document before the application's own scripts run. */
function installPageHelpers() {
  const clean = (text) =>
    String(text ?? '')
      .replace(/[\u200e\u200f\u2066-\u2069]/g, '')
      .replace(/\s+/g, ' ')
      .trim();

  const isShown = (element) => {
    if (!element.isConnected) return false;
    if (!element.checkVisibility({ visibilityProperty: true, contentVisibilityAuto: true })) return false;
    const box = element.getBoundingClientRect();
    return box.width > 0 && box.height > 0;
  };

  /**
   * Text of an element as it is announced: decorative parts, nested form controls and parts that are
   * not rendered (a caption that a narrow layout hides, for example) are left out.
   */
  const spokenText = (element) => {
    const parts = [];
    const visit = (node) => {
      if (node.nodeType === Node.TEXT_NODE) {
        parts.push(node.textContent);
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      if (node !== element) {
        if (node.matches('[aria-hidden="true"], input, select, textarea, svg')) return;
        const style = getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden') return;
      }
      for (const child of node.childNodes) visit(child);
    };
    visit(element);
    return clean(parts.join(''));
  };

  const nameOf = (element) => {
    const labelledBy = element.getAttribute('aria-labelledby');
    if (labelledBy) {
      const text = clean(
        labelledBy
          .split(/\s+/)
          .map((id) => {
            const target = document.getElementById(id);
            return target ? spokenText(target) : '';
          })
          .join(' '),
      );
      if (text) return text;
    }
    const ariaLabel = clean(element.getAttribute('aria-label'));
    if (ariaLabel) return ariaLabel;
    if (element.labels && element.labels.length > 0) return clean([...element.labels].map(spokenText).join(' '));
    if (element.matches('input, select, textarea')) return clean(element.getAttribute('title'));
    return spokenText(element) || clean(element.getAttribute('title'));
  };

  const SELECTORS = {
    button: 'button, summary, [role="button"], input[type="submit"], input[type="button"]',
    link: 'a[href]',
    tab: '[role="tab"]',
    field: 'input:not([type="hidden"]):not([type="file"]):not([type="checkbox"]):not([type="radio"]), select, textarea',
    checkbox: 'input[type="checkbox"]',
    radio: 'input[type="radio"]',
    group: '[role="group"], [role="radiogroup"], fieldset',
    heading: 'h1, h2, h3',
  };

  /** The part of the page a user can reach: the top-most open dialog, or the whole page. */
  const scope = () => {
    const dialogs = document.querySelectorAll('dialog[open]');
    return dialogs.length > 0 ? dialogs[dialogs.length - 1] : document.body;
  };

  const candidates = (role, rowText) => {
    let roots = [scope()];
    if (rowText !== null && rowText !== undefined) {
      const wanted = clean(rowText);
      roots = [...scope().querySelectorAll('tbody tr, li')].filter((row) => isShown(row) && clean(row.innerText).includes(wanted));
    }
    return roots.flatMap((root) => [...root.querySelectorAll(SELECTORS[role])]).filter(isShown);
  };

  const matching = (role, name, exact, rowText) => {
    const wanted = clean(name);
    return candidates(role, rowText).filter((element) => {
      const actual = nameOf(element);
      return exact ? actual === wanted : actual.includes(wanted);
    });
  };

  window.__e2e = {
    clean,
    isShown,
    nameOf,
    scope,
    matching,
    /** The single element of `role` named `name`; null when absent (or not yet enabled). Throws when ambiguous. */
    one(role, name, { exact = true, enabled = false, row = null, index = null } = {}) {
      const found = matching(role, name, exact, row);
      if (found.length === 0) return null;
      if (found.length > 1 && index === null) throw new Error(`${found.length} visible ${role} elements are named "${name}"`);
      const element = found[index ?? 0] ?? null;
      if (element === null) return null;
      if (enabled && (element.disabled || element.getAttribute('aria-disabled') === 'true')) return null;
      return element;
    },
    names: (role, row = null) => candidates(role, row).map(nameOf),
    text: () => clean(scope().innerText),
    /** Messages attached to a control through aria-describedby whose id marks them as errors. */
    errorOf(name) {
      const wanted = clean(name);
      const control = [...scope().querySelectorAll('input, select, textarea, [role="group"], [role="radiogroup"]')].find(
        (element) => isShown(element) && nameOf(element) === wanted,
      );
      if (!control) return null;
      return (control.getAttribute('aria-describedby') ?? '')
        .split(/\s+/)
        .filter((id) => id.endsWith('-error'))
        .map((id) => document.getElementById(id))
        .filter((element) => element && isShown(element))
        .map((element) => clean(element.innerText))
        .join(' ');
    },
    /** Why a click in the middle of `element` would not reach it, or null when it would. */
    obstruction(element) {
      if (!element.isConnected) return 'it was removed from the page after it was found (the page was rendered again in the meantime)';
      const box = element.getBoundingClientRect();
      const top = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
      if (top === null) return 'it is outside the viewport';
      if (top === element || element.contains(top) || top.closest('label')?.contains(element)) return null;
      return `it is covered by <${top.tagName.toLowerCase()} class="${top.className}"> "${clean(top.textContent).slice(0, 60)}"`;
    },
    /**
     * Visible controls that stick out of the viewport sideways where no scrolling can reach them
     * (content of a region that scrolls sideways itself, such as a wide table, is reachable).
     */
    cutOff() {
      const reachable = (element) => {
        for (let parent = element.parentElement; parent && parent !== document.documentElement; parent = parent.parentElement) {
          if (/(auto|scroll)/.test(getComputedStyle(parent).overflowX) && parent.scrollWidth > parent.clientWidth) return true;
        }
        return false;
      };
      return [...scope().querySelectorAll('button, summary, a[href], input:not([type="hidden"]):not([type="file"]), select, textarea')]
        .filter(isShown)
        .filter((element) => {
          const box = element.getBoundingClientRect();
          return (box.left < -1 || box.right > window.innerWidth + 1) && !reachable(element);
        })
        .map((element) => `<${element.tagName.toLowerCase()}> "${nameOf(element)}"`);
    },
    /** Problems with the open dialog: it must lie inside the viewport and scroll only up and down. */
    dialogProblems() {
      const dialog = scope();
      if (dialog === document.body) return [];
      const box = dialog.getBoundingClientRect();
      const problems = [];
      if (box.left < -1 || box.right > window.innerWidth + 1) problems.push(`the dialog sticks out sideways (${Math.round(box.left)}..${Math.round(box.right)} in a ${window.innerWidth}px viewport)`);
      if (box.top < -1 || box.bottom > window.innerHeight + 1) problems.push(`the dialog sticks out vertically (${Math.round(box.top)}..${Math.round(box.bottom)} in a ${window.innerHeight}px viewport)`);
      for (const part of [dialog, ...dialog.querySelectorAll('*')]) {
        if (part.scrollWidth > part.clientWidth + 1 && /(auto|scroll)/.test(getComputedStyle(part).overflowX) && !part.matches('.table-wrap, pre')) {
          problems.push(`<${part.tagName.toLowerCase()} class="${part.className}"> inside the dialog scrolls sideways`);
        }
      }
      return problems;
    },
    /** Visible interactive elements that a screen reader would announce without a name. */
    unnamed() {
      return [...scope().querySelectorAll('button, summary, a[href], input:not([type="hidden"]), select, textarea, [role="tab"], [role="group"], [role="radiogroup"]')]
        .filter((element) => isShown(element) && nameOf(element) === '')
        .map((element) => `<${element.tagName.toLowerCase()} class="${element.className}">`);
    },
  };

  document.addEventListener('securitypolicyviolation', (event) => {
    console.error(`Content-Security-Policy violation: ${event.violatedDirective} blocked ${event.blockedURI || 'inline code'}`);
  });
}

const IGNORED_CONSOLE = [
  // The response listener reports HTTP errors with their URL; the console line adds nothing.
  /^Failed to load resource: the server responded with a status of \d+/,
];

class Ui {
  #tracker;

  constructor({ page, baseUrl, downloadDir, tracker, openTab }) {
    this.page = page;
    this.baseUrl = baseUrl;
    this.downloadDir = downloadDir;
    this.#tracker = tracker;
    this.openTab = openTab;
  }

  // ---------------------------------------------------------------- navigation
  /** Loads the application at `hash` (for example "#/login") with a full page load. */
  async open(hash = '') {
    await this.page.goto(`${this.baseUrl}/${hash}`, { waitUntil: 'load' });
    await this.settled();
  }

  /** Changes the address inside the running application, like following a bookmark or typing the address. */
  async go(hash) {
    await this.page.evaluate((next) => {
      window.location.hash = next;
    }, hash);
    await this.settled();
  }

  async reload() {
    await this.page.reload({ waitUntil: 'load' });
    await this.settled();
  }

  async back() {
    await this.page.goBack();
    await this.settled();
  }

  hash() {
    return this.page.evaluate(() => window.location.hash);
  }

  async waitForHash(expected) {
    const matches = (hash) => (expected instanceof RegExp ? expected.test(hash) : hash === expected);
    await eventually(
      async () => matches(await this.hash()),
      async () => `expected the address to become ${expected}, but it is ${await this.hash()}`,
    );
    await this.settled();
  }

  /** Waits until the network is quiet and no loading indicator is left on the page. */
  async settled() {
    await this.page.waitForNetworkIdle({ idleTime: 120, timeout: DEFAULT_TIMEOUT_MS }).catch(() => {});
    await eventually(
      () => this.page.evaluate(() => document.querySelector('[role="status"] .spinner, .is-loading, .boot') === null),
      'the page kept showing a loading indicator',
    );
  }

  // ---------------------------------------------------------------- finding
  async #locate(role, name, options = {}) {
    const { timeout = DEFAULT_TIMEOUT_MS, ...query } = options;
    return eventually(
      async () => {
        const handle = await this.page.evaluateHandle((r, n, q) => window.__e2e.one(r, n, q), role, name, query);
        const element = handle.asElement();
        if (element === null) await handle.dispose();
        return element;
      },
      async () => {
        const names = await this.page.evaluate((r, row) => window.__e2e.names(r, row), role, query.row ?? null).catch(() => []);
        return `no ${query.enabled ? 'enabled ' : ''}${role} named "${name}"${query.row ? ` in the row "${query.row}"` : ''}; visible: ${JSON.stringify(names)}`;
      },
      timeout,
    );
  }

  /** Waits until the element has stopped moving (a drawer that slides in, a page that is still being laid out). */
  async #still(element, description) {
    let last = null;
    await eventually(async () => {
      const box = await element.evaluate((node) => {
        const { x, y, width, height } = node.getBoundingClientRect();
        return [x, y, width, height].map(Math.round).join(',');
      });
      const still = box === last;
      last = box;
      return still;
    }, `${description} kept moving`);
  }

  async #press(element, description) {
    await this.dismissToasts();
    await element.evaluate((node) => node.scrollIntoView({ block: 'center', inline: 'nearest' }));
    await this.#still(element, description);
    const obstruction = await element.evaluate((node) => window.__e2e.obstruction(node));
    assert.equal(obstruction, null, `${description} cannot be clicked: ${obstruction}`);
    await element.click();
  }

  /**
   * Clicks the button, link or tab with this accessible name. Options: `role`, `exact`, `row` (text of a table row), `index`.
   * Following a link inside the application is a navigation, so the call returns when the new page is shown (as `go()` does).
   * A button that changes the address (a filter form, for example) gives no such guarantee: wait for the address afterwards.
   */
  async click(name, { role = 'button', ...options } = {}) {
    const element = await this.#locate(role, name, { enabled: true, ...options });
    const navigates = await element.evaluate((node) => node instanceof HTMLAnchorElement && (node.getAttribute('href') ?? '').startsWith('#'));
    await this.#press(element, `${role} "${name}"`);
    await element.dispose();
    if (navigates) await this.settled();
  }

  /** Whether a visible element with this role and name exists right now. */
  async has(name, { role = 'button', exact = true, row = null } = {}) {
    return this.page.evaluate((r, n, e, w) => window.__e2e.matching(r, n, e, w).length > 0, role, name, exact, row);
  }

  async isEnabled(name, { role = 'button' } = {}) {
    const element = await this.#locate(role, name);
    return element.evaluate((node) => !node.disabled);
  }

  /** Names of the visible elements of a role, in document order. */
  names(role, { row = null } = {}) {
    return this.page.evaluate((r, w) => window.__e2e.names(r, w), role, row);
  }

  /** The value of an attribute (for example `aria-expanded`) of the element with this role and name. */
  async attribute(name, attribute, { role = 'button', ...options } = {}) {
    const element = await this.#locate(role, name, options);
    return element.evaluate((node, wanted) => node.getAttribute(wanted), attribute);
  }

  /** The accessible name of the element that has the keyboard focus ("" when nothing is focused). */
  focused() {
    return this.page.evaluate(() => {
      const element = document.activeElement;
      return element && element !== document.body ? window.__e2e.nameOf(element) : '';
    });
  }

  // ---------------------------------------------------------------- forms
  /** Replaces the content of the text field labelled `label` by typing `value`. */
  async fill(label, value, options = {}) {
    const element = await this.#locate('field', label, { enabled: true, ...options });
    await element.evaluate((node) => {
      node.scrollIntoView({ block: 'center', inline: 'nearest' });
      node.focus();
      node.value = '';
      node.dispatchEvent(new Event('input', { bubbles: true }));
    });
    if (String(value) !== '') await element.type(String(value));
    await element.dispose();
  }

  /** Sets a control's value directly (for native pickers, such as the time input, that cannot be typed into reliably). */
  async setValue(label, value) {
    const element = await this.#locate('field', label, { enabled: true });
    await element.evaluate((node, next) => {
      node.value = next;
      node.dispatchEvent(new Event('input', { bubbles: true }));
      node.dispatchEvent(new Event('change', { bubbles: true }));
    }, value);
    await element.dispose();
  }

  /** Chooses the option with the visible text `optionText` in the drop-down labelled `label`. */
  async select(label, optionText) {
    const element = await this.#locate('field', label, { enabled: true });
    const value = await eventually(
      () =>
        element.evaluate((node, wanted) => {
          const option = [...node.options].find((item) => window.__e2e.clean(item.textContent) === window.__e2e.clean(wanted));
          return option ? { value: option.value } : null;
        }, optionText),
      async () => `the list "${label}" has no option "${optionText}"; options: ${JSON.stringify(await element.evaluate((node) => [...node.options].map((item) => item.textContent)))}`,
    );
    await element.select(value.value);
    await element.dispose();
  }

  /** Options of a drop-down as shown to the user. */
  async options(label) {
    const element = await this.#locate('field', label);
    return element.evaluate((node) => [...node.options].map((item) => window.__e2e.clean(item.textContent)));
  }

  async setChecked(label, checked, options = {}) {
    const element = await this.#locate('checkbox', label, { enabled: true, ...options });
    if ((await element.evaluate((node) => node.checked)) !== checked) await this.#press(element, `check box "${label}"`);
    await element.dispose();
  }

  async isChecked(label, options = {}) {
    const element = await this.#locate('checkbox', label, options);
    return element.evaluate((node) => node.checked);
  }

  /** Picks the radio button labelled `label` by clicking its label, as a mouse user would. */
  async choose(label) {
    const element = await this.#locate('radio', label, { enabled: true });
    const target = await element.evaluateHandle((node) => node.closest('label') ?? node);
    await this.#press(target.asElement(), `radio button "${label}"`);
    await element.dispose();
  }

  /** Enters a Jalali date into the three-part date control labelled `label`. */
  async fillDate(label, { day, month, year }) {
    await this.fill(`${label}: روز`, day);
    await this.select(`${label}: ماه`, month);
    await this.fill(`${label}: سال`, year);
  }

  async value(label, options = {}) {
    const element = await this.#locate('field', label, options);
    return element.evaluate((node) => node.value);
  }

  /** The validation message announced for the control labelled `label` ("" when there is none). */
  async errorOf(label) {
    const message = await this.page.evaluate((name) => window.__e2e.errorOf(name), label);
    assert.notEqual(message, null, `no visible control is labelled "${label}"`);
    return message;
  }

  async waitForError(label, expected) {
    await eventually(
      async () => (await this.page.evaluate((name) => window.__e2e.errorOf(name), label))?.includes(expected),
      async () => `expected the field "${label}" to show the error "${expected}", but it shows "${await this.page.evaluate((name) => window.__e2e.errorOf(name), label)}"`,
    );
  }

  /** Puts files into the (hidden) file input of the visible upload area. */
  async chooseFiles(...paths) {
    const input = await eventually(async () => {
      const handle = await this.page.evaluateHandle(() => window.__e2e.scope().querySelector('input[type="file"]'));
      return handle.asElement();
    }, 'the page has no file input');
    await input.uploadFile(...paths);
    await input.dispose();
  }

  // ---------------------------------------------------------------- reading
  /** The text a user can currently read (inside the open dialog, if there is one). */
  text() {
    return this.page.evaluate(() => window.__e2e.text());
  }

  async hasText(expected) {
    return (await this.text()).includes(expected.replace(/\s+/g, ' ').trim());
  }

  async waitForText(expected, timeout = DEFAULT_TIMEOUT_MS) {
    await eventually(
      () => this.hasText(expected),
      async () => `expected to read "${expected}" on the page, which says: ${(await this.text()).slice(0, 700)}`,
      timeout,
    );
  }

  async waitForNoText(unexpected, timeout = DEFAULT_TIMEOUT_MS) {
    await eventually(async () => !(await this.hasText(unexpected)), `the page kept showing "${unexpected}"`, timeout);
  }

  toastText() {
    return this.page.evaluate(() => window.__e2e.clean(document.getElementById('toasts')?.innerText ?? ''));
  }

  /** Waits for a notification containing `expected`. */
  async waitForToast(expected) {
    await eventually(
      async () => (await this.toastText()).includes(expected),
      async () => `expected a notification saying "${expected}"; notifications: "${await this.toastText()}"; page: ${(await this.text()).slice(0, 400)}`,
    );
  }

  async dismissToasts() {
    await this.page.evaluate(() => {
      for (const button of document.querySelectorAll('#toasts button')) button.click();
    });
  }

  /**
   * Cell texts of the visible table (optionally the one with this caption): `{ headers, rows }`.
   * Columns that the layout hides (secondary columns on a phone) are left out, as they are for the user.
   */
  async table(caption = null) {
    const result = await this.page.evaluate((wanted) => {
      const { clean, isShown, scope } = window.__e2e;
      const tables = [...scope().querySelectorAll('table')].filter(isShown);
      const table = wanted === null ? tables[0] : tables.find((item) => clean(item.caption?.textContent) === clean(wanted));
      if (!table) return null;
      return {
        headers: [...table.querySelectorAll('thead th')].filter(isShown).map((cell) => clean(cell.textContent)),
        rows: [...table.querySelectorAll('tbody tr')].map((row) => [...row.cells].filter(isShown).map((cell) => clean(cell.innerText))),
      };
    }, caption);
    return result ?? { headers: [], rows: [] };
  }

  /** The cells of the first table row containing `text`, keyed by column header. */
  async row(text, caption = null) {
    const { headers, rows } = await this.table(caption);
    const cells = rows.find((row) => row.join(' | ').includes(text));
    return cells ? Object.fromEntries(headers.map((header, index) => [header, cells[index]])) : null;
  }

  async waitForRow(text, caption = null) {
    return eventually(
      () => this.row(text, caption),
      async () => `no table row contains "${text}"; rows: ${JSON.stringify((await this.table(caption)).rows)}`,
    );
  }

  /** Term → description of every visible definition list in scope. */
  definitions() {
    return this.page.evaluate(() => {
      const { clean, isShown, scope } = window.__e2e;
      const result = {};
      for (const term of scope().querySelectorAll('dt')) {
        if (isShown(term) && term.nextElementSibling?.tagName === 'DD') result[clean(term.innerText)] = clean(term.nextElementSibling.innerText);
      }
      return result;
    });
  }

  /** Names of the visible headings in scope. */
  headings() {
    return this.names('heading');
  }

  // ---------------------------------------------------------------- browser state
  localStorage(key) {
    return this.page.evaluate((name) => window.localStorage.getItem(name), key);
  }

  setLocalStorage(key, value) {
    return this.page.evaluate((name, next) => window.localStorage.setItem(name, next), key, value);
  }

  sessionStorage(key) {
    return this.page.evaluate((name) => window.sessionStorage.getItem(name), key);
  }

  /** Holds back every request whose URL contains `urlPart` for `milliseconds`, to widen a race window. */
  async delayRequests(urlPart, milliseconds) {
    await this.page.setRequestInterception(true);
    this.page.on('request', (request) => {
      if (request.isInterceptResolutionHandled()) return;
      if (request.url().includes(urlPart)) setTimeout(() => request.continue().catch(() => {}), milliseconds);
      else request.continue().catch(() => {});
    });
  }

  /** Runs `trigger()` and resolves to the file the browser saved because of it: `{ name, content }`. */
  async download(trigger) {
    const known = new Set(await readdir(this.downloadDir));
    await trigger();
    const name = await eventually(async () => {
      const files = (await readdir(this.downloadDir)).filter((file) => !known.has(file) && !file.endsWith('.crdownload') && !file.startsWith('.'));
      return files[0] ?? null;
    }, 'the browser did not save a file');
    return { name, content: await readFile(path.join(this.downloadDir, name)) };
  }

  /** Saves a picture of the viewport once transitions (a drawer sliding in, a toast appearing) have run to their end. */
  async screenshot(name) {
    const file = path.join(SCREENSHOT_DIR, `${name}.png`);
    await this.page.evaluate(() =>
      Promise.all(
        document
          .getAnimations()
          // A spinner turns for ever; only animations that end are waited for.
          .filter((animation) => Number.isFinite(animation.effect?.getComputedTiming().endTime))
          .map((animation) => animation.finished.catch(() => {})),
      ),
    );
    await this.page.screenshot({ path: file });
    return file;
  }

  /**
   * Layout checks that hold on every page and in every dialog: the page does not scroll sideways,
   * no control is cut off, an open dialog fits the screen and every control has a name.
   */
  async assertLayout(label) {
    const { scrollWidth, clientWidth, unnamed, cutOff, dialog } = await this.page.evaluate(() => ({
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      unnamed: window.__e2e.unnamed(),
      cutOff: window.__e2e.cutOff(),
      dialog: window.__e2e.dialogProblems(),
    }));
    assert.equal(scrollWidth, clientWidth, `${label}: the page scrolls sideways (${scrollWidth}px of content in a ${clientWidth}px viewport)`);
    assert.deepEqual(cutOff, [], `${label}: controls that are cut off at the edge of the screen`);
    assert.deepEqual(dialog, [], `${label}: the dialog does not fit the screen`);
    assert.deepEqual(unnamed, [], `${label}: controls without an accessible name`);
  }

  // ---------------------------------------------------------------- problems
  /** Announces that an HTTP error with this status from a URL containing `urlPart` is part of the scenario. */
  expectHttp(status, urlPart) {
    this.#tracker.expected.push({ status, urlPart });
  }

  /** Requests the page has sent whose URL contains `urlPart`. */
  requests(urlPart) {
    return this.#tracker.requests.filter((request) => request.url.includes(urlPart));
  }

  problems() {
    const { expected, responses } = this.#tracker;
    const seen = new Set();
    const unexpected = [];
    for (const response of responses) {
      const fits = (item) => item.status === response.status && response.url.includes(item.urlPart);
      // An error answers the announcement that is still open; "/shipments" must not swallow the error meant for "/shipments/<id>/tracking-code".
      const match = expected.find((item) => !seen.has(item) && fits(item)) ?? expected.find(fits);
      if (match) seen.add(match);
      else unexpected.push(`HTTP ${response.status} for ${response.method} ${response.url}`);
    }
    const missing = expected.filter((item) => !seen.has(item)).map((item) => `the expected HTTP ${item.status} from ${item.urlPart} never happened`);
    return [...this.#tracker.problems, ...unexpected, ...missing];
  }

  assertClean() {
    assert.deepEqual(this.problems(), [], 'the page reported problems');
  }
}

function watch(page, tracker) {
  page.on('console', (message) => {
    if (!['error', 'warning'].includes(message.type())) return;
    const text = message.text();
    if (!IGNORED_CONSOLE.some((pattern) => pattern.test(text))) tracker.problems.push(`console ${message.type()}: ${text}`);
  });
  page.on('pageerror', (error) => tracker.problems.push(`uncaught exception: ${error.message}`));
  page.on('request', (request) => tracker.requests.push({ method: request.method(), url: request.url() }));
  page.on('requestfailed', (request) => {
    const reason = request.failure()?.errorText ?? 'unknown';
    // The application cancels the requests of a page the user has left.
    if (reason !== 'net::ERR_ABORTED') tracker.problems.push(`request failed (${reason}): ${request.method()} ${request.url()}`);
  });
  page.on('response', (response) => {
    if (response.status() >= 400) tracker.responses.push({ status: response.status(), method: response.request().method(), url: response.url() });
  });
}

const slug = (text) =>
  text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 80);

/**
 * Boots the backend and a browser once for the test file that calls it.
 *
 * `settings` are extra environment variables for the backend. `prepare(app)` arranges
 * test data once everything is running (file-level `before` hooks of node:test run
 * concurrently, so the preparation cannot be a second hook).
 */
export function useApp({ settings = {}, prepare = null } = {}) {
  let backend = null;
  let browser = null;
  /**
   * Runs `scenario(ui)` in a fresh browser profile (own storage, own downloads). Afterwards the
   * scenario fails if the page logged an error or got an HTTP error that was not expected.
   * `origin` (a function returning the address) points the browser at another server than the backend.
   */
  async function session(scenario, { viewport = DESKTOP, name = 'scenario', origin = null } = {}) {
    const context = await browser.createBrowserContext();
    const downloadDir = await mkdtemp(path.join(os.tmpdir(), 'armin-e2e-downloads-'));
    const control = await browser.target().createCDPSession();
    await control.send('Browser.setDownloadBehavior', { behavior: 'allow', browserContextId: context.id, downloadPath: downloadDir });
    const tabs = [];

    const openTab = async () => {
      const page = await context.newPage();
      await page.setViewport(viewport);
      await page.evaluateOnNewDocument(installPageHelpers);
      const tracker = { problems: [], responses: [], requests: [], expected: [] };
      watch(page, tracker);
      const ui = new Ui({ page, baseUrl: origin === null ? backend.baseUrl : origin(), downloadDir, tracker, openTab });
      tabs.push(ui);
      return ui;
    };

    try {
      const ui = await openTab();
      await scenario(ui);
      for (const tab of tabs) tab.assertClean();
    } catch (error) {
      for (const [index, tab] of tabs.entries()) {
        await tab.screenshot(`failed-${slug(name)}${index > 0 ? `-tab${index + 1}` : ''}`).catch(() => {});
        const problems = tab.problems();
        if (problems.length > 0) console.error(`Problems reported by tab ${index + 1}:\n  ${problems.join('\n  ')}`);
      }
      const log = backend.logs().trim();
      if (log) console.error(`Backend log (tail):\n${log.split('\n').slice(-25).join('\n')}`);
      throw error;
    } finally {
      await control.detach().catch(() => {});
      await context.close().catch(() => {});
      await rm(downloadDir, { recursive: true, force: true });
    }
  }

  const app = {
    get baseUrl() {
      return backend.baseUrl;
    },
    get apiUrl() {
      return backend.apiUrl;
    },
    get password() {
      return backend.password;
    },
    get api() {
      return apiClient(backend.apiUrl);
    },
    session,
    /** Declares a test that runs `scenario(ui)` through `session()`. */
    scenario(title, scenario, options = {}) {
      test(title, { timeout: 180_000 }, (t) => session(scenario, { name: t.name, ...options }));
    },
  };

  before(
    async () => {
      backend = await startBackend(settings);
      browser = await launchBrowser();
      await prepare?.(app);
    },
    { timeout: 300_000 },
  );
  after(
    async () => {
      await browser?.close().catch(() => {});
      await backend?.stop();
    },
    { timeout: 60_000 },
  );

  return app;
}

/** Signs in through the login form and waits for the dashboard (or `landing`). */
export async function signIn(ui, username, password, { landing = '#/dashboard' } = {}) {
  if (!(await ui.hash()).startsWith('#/login')) await ui.open('#/login');
  await ui.fill('نام کاربری', username);
  await ui.fill('رمز عبور', password);
  await ui.click('ورود');
  await ui.waitForHash(landing);
}
