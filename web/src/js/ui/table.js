/** Data tables, pagination and small presentational pieces shared by the pages. */

import { h, icon, ltr } from '../core/dom.js';
import { formatNumber, toPersianDigits } from '../core/format.js';

/**
 * Renders a table. `columns`: `[{ header, cell(row) -> Node | string, className?, headerClass? }]`.
 * Cell content is inserted as text unless it is a Node.
 */
export function dataTable({ columns, rows, caption = null, rowKey = null }) {
  return h(
    'div',
    { class: 'table-wrap' },
    h(
      'table',
      { class: 'table' },
      caption && h('caption', { class: 'sr-only' }, caption),
      h('thead', {}, h('tr', {}, columns.map((column) => h('th', { scope: 'col', class: column.headerClass ?? column.className ?? null }, column.header)))),
      h(
        'tbody',
        {},
        rows.map((row) =>
          h('tr', { dataset: rowKey ? { key: String(rowKey(row)) } : {} }, columns.map((column) => h('td', { class: column.className ?? null }, column.cell(row)))),
        ),
      ),
    ),
  );
}

/** "page X of Y" with previous/next buttons. `onPage(page)` is called with the requested page number. */
export function paginationBar(pagination, onPage) {
  const { page, total, total_pages: totalPages, has_next: hasNext, has_prev: hasPrev } = pagination;
  return h(
    'nav',
    { class: 'pagination', 'aria-label': 'صفحه‌بندی' },
    h('span', {}, `${formatNumber(total)} مورد`, totalPages > 1 ? ` · صفحهٔ ${toPersianDigits(page)} از ${toPersianDigits(totalPages)}` : ''),
    totalPages > 1 &&
      h(
        'div',
        { class: 'row' },
        h('button', { type: 'button', class: 'btn btn-secondary btn-sm', disabled: !hasPrev, onClick: () => onPage(page - 1) }, icon('chevron-right', { size: 16 }), 'قبلی'),
        h('button', { type: 'button', class: 'btn btn-secondary btn-sm', disabled: !hasNext, onClick: () => onPage(page + 1) }, 'بعدی', icon('chevron-left', { size: 16 })),
      ),
  );
}

export function badge(text, kind = 'neutral') {
  return h('span', { class: `badge ${kind === 'neutral' ? '' : `badge-${kind}`}`.trim() }, text);
}

export function activeBadge(isActive) {
  return isActive ? badge('فعال', 'success') : badge('غیرفعال', 'danger');
}

export function shipmentStatusBadge(status) {
  return status === 'ARCHIVED' ? badge('بایگانی‌شده', 'warning') : badge('فعال', 'success');
}

export function trackingCodeTypeLabel(type) {
  return type === 'MANUAL' ? 'دستی' : 'خودکار';
}

export function roleLabel(role) {
  return role === 'SUPER_ADMIN' ? 'مدیر مرکزی' : role === 'CUSTOMER' ? 'مشتری' : 'کارمند';
}

/** A tracking code rendered left-to-right in a monospace face. */
export function trackingCode(code) {
  return ltr(code, 'code nowrap');
}

export function iconButton({ iconName, label, onClick, className = 'btn btn-ghost btn-icon', disabled = false }) {
  return h('button', { type: 'button', class: className, title: label, 'aria-label': label, disabled, onClick }, icon(iconName));
}

/** A definition list: `items` is `[[term, description Node | string], ...]`; null descriptions are skipped. */
export function keyValueList(items) {
  return h(
    'dl',
    { class: 'kv' },
    items.filter(([, description]) => description !== null && description !== undefined).map(([term, description]) => h('div', {}, h('dt', {}, term), h('dd', {}, description))),
  );
}
