import { h, icon, ltr } from '../core/dom.js';
import { formatDateTime } from '../core/format.js';
import { openModal } from '../ui/dialog.js';
import { emptyBlock } from '../ui/feedback.js';
import { INVALID_DATE_MESSAGE, buildForm, endOfLocalDay, filterPanel, jalaliDateField, selectField, startOfLocalDay } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { badge, dataTable, iconButton, keyValueList, paginationBar } from '../ui/table.js';
import { asyncBlock, loadListPage } from './shared.js';

/** Persian names of the audit actions recorded by the backend; unknown actions are shown verbatim. */
const ACTION_LABELS = {
  LOGIN_SUCCESS: 'ورود موفق',
  LOGIN_FAILED: 'ورود ناموفق',
  LOGIN_BLOCKED: 'ورود مسدودشده',
  LOGOUT: 'خروج',
  PASSWORD_CHANGED: 'تغییر رمز عبور',
  PASSWORD_CHANGE_FAILED: 'تلاش ناموفق برای تغییر رمز',
  REFRESH_TOKEN_REUSE_DETECTED: 'استفادهٔ دوباره از توکن نوسازی',
  ACCESS_DENIED: 'دسترسی غیرمجاز',
  ADMIN_CREATED: 'ایجاد مدیر مرکزی',
  COMPANY_CREATED: 'ایجاد شرکت',
  COMPANY_UPDATED: 'ویرایش شرکت',
  COMPANY_ACTIVATED: 'فعال‌سازی شرکت',
  COMPANY_DEACTIVATED: 'غیرفعال‌سازی شرکت',
  USER_CREATED: 'ایجاد کارمند',
  USER_UPDATED: 'ویرایش کارمند',
  USER_ACTIVATED: 'فعال‌سازی کارمند',
  USER_DEACTIVATED: 'غیرفعال‌سازی کارمند',
  USER_PASSWORD_RESET: 'بازنشانی رمز کارمند',
  SHIPMENT_CREATED: 'ثبت محموله',
  SHIPMENT_UPDATED: 'ویرایش محموله',
  SHIPMENT_ARCHIVED: 'بایگانی محموله',
  SHIPMENT_UNARCHIVED: 'خروج محموله از بایگانی',
  TRACKING_CODE_CHANGED: 'تغییر کد رهگیری',
  PRODUCT_VALUES_UPDATED: 'ویرایش مشخصات کالا',
  PRODUCT_FIELD_CREATED: 'تعریف فیلد',
  PRODUCT_FIELD_UPDATED: 'ویرایش فیلد',
  DOCUMENT_UPLOADED: 'بارگذاری سند',
  DOCUMENT_UPLOAD_REJECTED: 'رد شدن بارگذاری سند',
  DOCUMENT_DOWNLOADED: 'دریافت سند',
  DOCUMENT_VISIBILITY_CHANGED: 'تغییر نمایش سند به مشتری',
  DOCUMENT_DELETED: 'حذف سند',
  DOCUMENT_INTEGRITY_FAILURE: 'خطای یکپارچگی فایل سند',
  CUSTOMER_LOOKUP_SUCCESS: 'رهگیری موفق مشتری',
  CUSTOMER_LOOKUP_FAILED: 'رهگیری ناموفق مشتری',
  CUSTOMER_DOCUMENT_DOWNLOADED: 'دریافت سند توسط مشتری',
  CUSTOMER_SESSIONS_REVOKED: 'لغو دسترسی مشتریان',
};

const ENTITY_LABELS = {
  user: 'کاربر',
  company: 'شرکت',
  shipment: 'محموله',
  document: 'سند',
  product_field_definition: 'فیلد محموله',
};

const WARNING_ACTIONS = new Set([
  'LOGIN_FAILED',
  'LOGIN_BLOCKED',
  'PASSWORD_CHANGE_FAILED',
  'REFRESH_TOKEN_REUSE_DETECTED',
  'ACCESS_DENIED',
  'DOCUMENT_UPLOAD_REJECTED',
  'DOCUMENT_INTEGRITY_FAILURE',
  'CUSTOMER_LOOKUP_FAILED',
]);

export const actionLabel = (action) => ACTION_LABELS[action] ?? action;
const entityLabel = (type) => ENTITY_LABELS[type] ?? type;

function showDetails(entry) {
  openModal({
    title: actionLabel(entry.action),
    size: 'lg',
    content: h(
      'div',
      { class: 'stack' },
      keyValueList([
        ['زمان', formatDateTime(entry.created_at, { style: 'long' })],
        ['کاربر', entry.user ? h('span', {}, entry.user.full_name, ' (', ltr(entry.user.username, 'code'), ')') : 'بدون کاربر (مشتری یا سامانه)'],
        ['رویداد', ltr(entry.action, 'code')],
        ['موجودیت', entityLabel(entry.entity_type)],
        ['شناسهٔ موجودیت', entry.entity_id ? ltr(entry.entity_id, 'code') : null],
        ['نشانی IP', entry.ip_address ? ltr(entry.ip_address, 'code') : null],
        ['شناسهٔ درخواست', entry.request_id ? ltr(entry.request_id, 'code') : null],
      ]),
      entry.metadata && Object.keys(entry.metadata).length > 0
        ? h('div', { class: 'stack-sm' }, h('h3', {}, 'جزئیات'), h('pre', { class: 'json', dir: 'ltr' }, JSON.stringify(entry.metadata, null, 2)))
        : null,
      entry.entity_type === 'shipment' && entry.entity_id
        ? h('div', {}, h('a', { class: 'btn btn-secondary btn-sm', href: `#/shipments/${entry.entity_id}` }, icon('package', { size: 16 }), 'مشاهدهٔ محموله'))
        : null,
    ),
  });
}

export function auditLogsPage(ctx) {
  const { query } = ctx;
  const hasFilters = ['action', 'entity_type', 'created_from', 'created_to'].some((name) => query[name]);

  const fields = {
    action: selectField({
      label: 'رویداد',
      value: query.action ?? '',
      placeholder: 'همهٔ رویدادها',
      options: Object.entries(ACTION_LABELS).map(([value, label]) => ({ value, label })),
    }),
    entity_type: selectField({
      label: 'موجودیت',
      value: query.entity_type ?? '',
      placeholder: 'همه',
      options: Object.entries(ENTITY_LABELS).map(([value, label]) => ({ value, label })),
    }),
    created_from: jalaliDateField({ label: 'از تاریخ', value: query.created_from ?? '' }),
    created_to: jalaliDateField({ label: 'تا تاریخ', value: query.created_to ?? '' }),
  };
  const filters = buildForm({
    fields,
    submitLabel: 'اعمال فیلتر',
    submitIcon: 'search',
    submitClass: 'btn btn-secondary',
    actionsClass: 'row',
    extraActions: hasFilters ? [h('a', { class: 'btn btn-ghost', href: '#/audit-logs' }, 'حذف فیلترها')] : [],
    validate: (values) => ({
      ...(values.created_from === null ? { created_from: INVALID_DATE_MESSAGE } : {}),
      ...(values.created_to === null ? { created_to: INVALID_DATE_MESSAGE } : {}),
    }),
    onSubmit: async (values) => ctx.setQuery({ ...values, page: null }),
  });

  const list = asyncBlock(
    ctx,
    (signal) =>
      loadListPage(
        ctx,
        '/audit-logs',
        {
          company_id: query.company_id,
          action: query.action,
          entity_type: query.entity_type,
          created_from: query.created_from ? startOfLocalDay(query.created_from) : null,
          created_to: query.created_to ? endOfLocalDay(query.created_to) : null,
        },
        signal,
      ),
    (data) =>
      data.items.length === 0
        ? emptyBlock({ iconName: 'list', title: hasFilters ? 'رویدادی با این مشخصات پیدا نشد.' : 'هنوز رویدادی ثبت نشده است.' })
        : h(
            'div',
            {},
            dataTable({
              caption: 'گزارش رویدادها',
              rowKey: (entry) => entry.id,
              rows: data.items,
              columns: [
                { header: 'زمان', className: 'nowrap', cell: (entry) => formatDateTime(entry.created_at) },
                { header: 'رویداد', cell: (entry) => badge(actionLabel(entry.action), WARNING_ACTIONS.has(entry.action) ? 'warning' : 'info') },
                { header: 'کاربر', cell: (entry) => entry.user?.full_name ?? '—' },
                { header: 'موجودیت', className: 'hide-mobile', cell: (entry) => entityLabel(entry.entity_type) },
                { header: 'نشانی IP', className: 'hide-mobile', cell: (entry) => (entry.ip_address ? ltr(entry.ip_address, 'code') : '—') },
                {
                  header: h('span', { class: 'sr-only' }, 'عملیات'),
                  cell: (entry) => h('div', { class: 'actions' }, iconButton({ iconName: 'eye', label: 'نمایش جزئیات رویداد', onClick: () => showDetails(entry) })),
                },
              ],
            }),
            paginationBar(data.pagination, (page) => ctx.setQuery({ page })),
          ),
  );

  return {
    title: 'گزارش رویدادها',
    element: h(
      'div',
      {},
      pageHeader({ title: 'گزارش رویدادها', description: 'سابقهٔ ورودها، تغییرات و دسترسی‌ها برای بازبینی امنیتی. این گزارش قابل ویرایش یا حذف نیست.' }),
      h('section', { class: 'card' }, filterPanel(filters, { active: hasFilters }), list.element),
    ),
  };
}
