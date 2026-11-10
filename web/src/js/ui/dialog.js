/** Modal dialogs built on the native <dialog> element (focus trapping and Escape handling come for free). */

import { h, icon } from '../core/dom.js';
import { errorMessage, toast, withBusyButton } from './feedback.js';

let modalCount = 0;

/**
 * Opens a modal. `content` is a Node (typically a form). Returns `{ dialog, close }`.
 * `onClose` runs once after the dialog is closed by any means.
 */
export function openModal({ title, content, size = 'md', onClose = null }) {
  const titleId = `modal-title-${(modalCount += 1)}`;
  const dialog = h(
    'dialog',
    { class: `modal ${size === 'lg' ? 'modal-lg' : ''}`.trim(), 'aria-labelledby': titleId },
    h(
      'div',
      { class: 'modal-header' },
      h('h2', { id: titleId }, title),
      h('button', { type: 'button', class: 'btn btn-ghost btn-icon', 'aria-label': 'بستن', onClick: () => dialog.close() }, icon('x')),
    ),
    h('div', { class: 'modal-body' }, content),
  );
  dialog.addEventListener('close', () => {
    dialog.remove();
    onClose?.();
  });
  // A click on the backdrop (the dialog element itself, outside its content box) closes the dialog.
  dialog.addEventListener('mousedown', (event) => {
    if (event.target !== dialog) return;
    const box = dialog.getBoundingClientRect();
    const inside = event.clientX >= box.left && event.clientX <= box.right && event.clientY >= box.top && event.clientY <= box.bottom;
    if (!inside) dialog.close();
  });
  document.body.append(dialog);
  dialog.showModal();
  return { dialog, close: () => dialog.open && dialog.close() };
}

/** Asks for confirmation. Resolves to `true` only when the user presses the confirm button. */
export function confirmDialog({ title, message, confirmLabel = 'تأیید', cancelLabel = 'انصراف', danger = false }) {
  return new Promise((resolve) => {
    let confirmed = false;
    const confirm = h('button', { type: 'button', class: danger ? 'btn btn-danger' : 'btn' }, confirmLabel);
    const cancel = h('button', { type: 'button', class: 'btn btn-secondary', autofocus: true }, cancelLabel);
    const modal = openModal({
      title,
      content: h('div', { class: 'stack' }, h('p', {}, message), h('div', { class: 'form-actions' }, cancel, confirm)),
      onClose: () => resolve(confirmed),
    });
    confirm.addEventListener('click', () => {
      confirmed = true;
      modal.close();
    });
    cancel.addEventListener('click', () => modal.close());
  });
}

/**
 * Confirms and then runs an API action started from `button`, reporting the outcome with toasts.
 * Resolves to the action's result, or `undefined` when cancelled or failed.
 */
export async function confirmAndRun({ button, confirm = null, action, successMessage = null, onDone = null }) {
  if (confirm && !(await confirmDialog(confirm))) return undefined;
  return withBusyButton(button, async () => {
    try {
      const result = await action();
      toast.success(successMessage ?? result?.message ?? 'انجام شد.');
      await onDone?.(result);
      return result;
    } catch (error) {
      toast.error(errorMessage(error));
      return undefined;
    }
  });
}
