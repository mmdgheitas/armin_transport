/** Toast notifications and the standard loading / empty / error blocks. */

import { ApiError } from '../core/api.js';
import { formatDuration } from '../core/format.js';
import { h, icon } from '../core/dom.js';

const TOAST_LIFETIME_MS = { success: 4500, info: 4500, error: 8000 };
const MAX_TOASTS = 4;

function toastHost() {
  return document.getElementById('toasts');
}

function showToast(kind, message) {
  const host = toastHost();
  if (!host || !message) return;
  const element = h(
    'div',
    { class: `toast toast-${kind}`, role: kind === 'error' ? 'alert' : null },
    icon(kind === 'success' ? 'check' : kind === 'error' ? 'alert' : 'info'),
    h('span', {}, message),
    h('button', { type: 'button', 'aria-label': 'بستن پیام', onClick: () => element.remove() }, icon('x', { size: 16 })),
  );
  while (host.children.length >= MAX_TOASTS) host.firstElementChild.remove();
  host.append(element);
  setTimeout(() => element.remove(), TOAST_LIFETIME_MS[kind]);
}

export const toast = {
  success: (message) => showToast('success', message),
  info: (message) => showToast('info', message),
  error: (message) => showToast('error', message),
};

/** A user-presentable Persian message for any thrown value. */
export function errorMessage(error) {
  if (error instanceof ApiError) {
    if (error.status === 429 && error.retryAfterSeconds) {
      return `${error.message} (${formatDuration(error.retryAfterSeconds)} دیگر دوباره تلاش کنید.)`;
    }
    return error.message;
  }
  return 'خطای غیرمنتظره‌ای رخ داد. لطفاً دوباره تلاش کنید.';
}

export function loadingBlock(text = 'در حال دریافت اطلاعات…') {
  return h('div', { class: 'loading', role: 'status' }, h('span', { class: 'spinner', 'aria-hidden': 'true' }), h('span', {}, text));
}

export function emptyBlock({ iconName = 'file', title, text = null, action = null }) {
  return h('div', { class: 'empty' }, icon(iconName, { size: 40 }), h('strong', {}, title), text && h('span', {}, text), action);
}

export function errorBlock(error, onRetry = null) {
  const requestId = error instanceof ApiError ? error.requestId : null;
  return h(
    'div',
    { class: 'empty', role: 'alert' },
    icon('alert', { size: 40 }),
    h('strong', {}, errorMessage(error)),
    requestId && h('span', { class: 'small' }, 'شناسهٔ پیگیری: ', h('bdi', { dir: 'ltr', class: 'code' }, requestId)),
    onRetry && h('button', { type: 'button', class: 'btn btn-secondary', onClick: onRetry }, icon('refresh', { size: 16 }), 'تلاش دوباره'),
  );
}

export function alertBox(kind, ...content) {
  const iconName = kind === 'success' ? 'check' : kind === 'info' ? 'info' : 'alert';
  return h('div', { class: `alert alert-${kind}`, role: kind === 'danger' ? 'alert' : null }, icon(iconName), h('div', { class: 'grow' }, ...content));
}

/** Runs `task` while `button` shows a spinner and is disabled; double submissions are impossible. */
export async function withBusyButton(button, task) {
  if (button.disabled) return undefined;
  button.disabled = true;
  button.classList.add('is-loading');
  try {
    return await task();
  } finally {
    button.disabled = false;
    button.classList.remove('is-loading');
  }
}
