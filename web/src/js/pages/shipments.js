import { h, icon } from '../core/dom.js';
import { formatDateTime, formatNumber } from '../core/format.js';
import { emptyBlock } from '../ui/feedback.js';
import { INVALID_DATE_MESSAGE, buildForm, endOfLocalDay, filterPanel, jalaliDateField, selectField, startOfLocalDay, textField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { dataTable, paginationBar, shipmentStatusBadge, trackingCode, trackingCodeTypeLabel } from '../ui/table.js';
import { asyncBlock, companyOptions, loadAll, loadListPage } from './shared.js';

const SORT_OPTIONS = [
  { value: '-created_at', label: 'جدیدترین' },
  { value: 'created_at', label: 'قدیمی‌ترین' },
  { value: '-updated_at', label: 'آخرین تغییر' },
  { value: 'tracking_code', label: 'کد رهگیری (صعودی)' },
];

export function shipmentsPage(ctx) {
  const { query, session } = ctx;
  const isGlobal = session.isGlobalScope;
  if (isGlobal && !query.company_id) {
    const companies = asyncBlock(ctx, () => loadAll(ctx, '/companies'), (items) =>
      h('div', { class: 'stack' }, ...items.map((company) =>
        h('a', { class: 'card card-body row-link', href: `#/shipments?company_id=${company.id}&status=ACTIVE` }, company.name))));
    return { title: 'محموله‌ها بر اساس شرکت', element: h('div', {},
      pageHeader({ title: 'محموله‌ها بر اساس شرکت', description: 'برای مشاهدهٔ بارهای فعال، شرکت را انتخاب کنید.' }), companies.element) };
  }
  const canCreate = session.can('shipment:create');
  const hasFilters = ['q', 'status', 'company_id', 'tracking_code_type', 'created_from', 'created_to'].some((name) => query[name]);

  const fields = {
    q: textField({ label: 'جست‌وجو', value: query.q ?? '', placeholder: 'کد رهگیری یا توضیحات', maxlength: 100, className: 'wide' }),
    status: selectField({
      label: 'وضعیت',
      value: query.status ?? '',
      placeholder: 'همه',
      options: [
        { value: 'ACTIVE', label: 'فعال' },
        { value: 'ARCHIVED', label: 'بایگانی‌شده' },
      ],
    }),
    tracking_code_type: selectField({
      label: 'نوع کد رهگیری',
      value: query.tracking_code_type ?? '',
      placeholder: 'همه',
      options: [
        { value: 'AUTO', label: 'خودکار' },
        { value: 'MANUAL', label: 'دستی' },
      ],
    }),
    created_from: jalaliDateField({ label: 'ثبت از تاریخ', value: query.created_from ?? '' }),
    created_to: jalaliDateField({ label: 'ثبت تا تاریخ', value: query.created_to ?? '' }),
    sort: selectField({ label: 'ترتیب', value: query.sort ?? '-created_at', options: SORT_OPTIONS }),
  };
  if (isGlobal) fields.company_id = selectField({ label: 'شرکت', value: '', placeholder: 'همهٔ شرکت‌ها', options: [] });

  const filters = buildForm({
    fields,
    layout: [fields.q.element, isGlobal && fields.company_id.element, fields.status.element, fields.tracking_code_type.element, fields.created_from.element, fields.created_to.element, fields.sort.element].filter(Boolean),
    submitLabel: 'اعمال فیلتر',
    submitIcon: 'search',
    submitClass: 'btn btn-secondary',
    actionsClass: 'row',
    extraActions: hasFilters ? [h('a', { class: 'btn btn-ghost', href: '#/shipments' }, 'حذف فیلترها')] : [],
    validate: (values) => ({
      ...(values.created_from === null ? { created_from: INVALID_DATE_MESSAGE } : {}),
      ...(values.created_to === null ? { created_to: INVALID_DATE_MESSAGE } : {}),
    }),
    onSubmit: async (values) => ctx.setQuery({ ...values, q: values.q.trim(), sort: values.sort === '-created_at' ? null : values.sort, page: null }),
  });

  if (isGlobal) {
    loadAll(ctx, '/companies')
      .then((companies) => {
        const select = fields.company_id.control;
        for (const option of companyOptions(companies)) select.append(h('option', { value: option.value }, option.label));
        select.value = query.company_id ?? '';
      })
      .catch(() => {
        // The list still works without the company filter; the table reports real failures.
      });
  }

  const list = asyncBlock(
    ctx,
    (signal) =>
      loadListPage(
        ctx,
        '/shipments',
        {
          q: query.q,
          status: query.status,
          company_id: isGlobal ? query.company_id : null,
          tracking_code_type: query.tracking_code_type,
          created_from: query.created_from ? startOfLocalDay(query.created_from) : null,
          created_to: query.created_to ? endOfLocalDay(query.created_to) : null,
          sort: query.sort,
        },
        signal,
      ),
    (data) =>
      data.items.length === 0
        ? emptyBlock({
            iconName: 'package',
            title: hasFilters ? 'محموله‌ای با این مشخصات پیدا نشد.' : 'هنوز محموله‌ای ثبت نشده است.',
            text: hasFilters ? 'فیلترها را تغییر دهید یا حذف کنید.' : null,
            action: !hasFilters && canCreate ? h('a', { class: 'btn', href: '#/shipments/new' }, icon('plus', { size: 16 }), 'ثبت محمولهٔ جدید') : null,
          })
        : h(
            'div',
            {},
            dataTable({
              caption: 'فهرست محموله‌ها',
              rowKey: (shipment) => shipment.id,
              rows: data.items,
              columns: [
                {
                  header: 'کد رهگیری',
                  cell: (shipment) => h('a', { class: 'row-link', href: `#/shipments/${shipment.id}` }, trackingCode(shipment.tracking_code)),
                },
                { header: 'توضیحات', className: 'truncate', cell: (shipment) => shipment.description ?? '—' },
                ...(isGlobal ? [{ header: 'شرکت', cell: (shipment) => shipment.company?.name ?? '—' }] : []),
                { header: 'ثبت‌کننده', className: 'hide-mobile', cell: (shipment) => shipment.created_by?.full_name ?? '—' },
                { header: 'نوع کد', className: 'hide-mobile', cell: (shipment) => trackingCodeTypeLabel(shipment.tracking_code_type) },
                { header: 'سندها', cell: (shipment) => formatNumber(shipment.document_count) },
                { header: 'وضعیت', cell: (shipment) => shipmentStatusBadge(shipment.status) },
                { header: 'تاریخ ثبت', className: 'nowrap', cell: (shipment) => formatDateTime(shipment.created_at) },
              ],
            }),
            paginationBar(data.pagination, (page) => ctx.setQuery({ page })),
          ),
  );

  return {
    title: 'محموله‌ها',
    element: h(
      'div',
      {},
      pageHeader({
        title: 'محموله‌ها',
        description: isGlobal ? 'محموله‌های همهٔ شرکت‌ها' : 'محموله‌های شرکت شما',
        actions: canCreate ? [h('a', { class: 'btn', href: '#/shipments/new' }, icon('plus', { size: 16 }), 'ثبت محمولهٔ جدید')] : [],
      }),
      h('section', { class: 'card' }, filterPanel(filters, { active: hasFilters }), list.element),
    ),
  };
}
