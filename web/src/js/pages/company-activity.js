import { h } from '../core/dom.js';
import { formatDateTime } from '../core/format.js';
import { emptyBlock } from '../ui/feedback.js';
import { pageHeader } from '../ui/layout.js';
import { dataTable, paginationBar } from '../ui/table.js';
import { asyncBlock, loadAll, loadListPage } from './shared.js';
import { actionLabel } from './audit-logs.js';

export function companyActivityPage(ctx) {
  const companyId = ctx.session.user?.role === 'CUSTOMER' ? ctx.session.user.company_id : ctx.query.company_id;
  const block = companyId
    ? asyncBlock(ctx, (signal) => loadListPage(ctx, `/companies/${encodeURIComponent(companyId)}/activity`, {}, signal),
      (data) => data.items.length === 0 ? emptyBlock({ iconName: 'list', title: 'هنوز فعالیتی ثبت نشده است.' }) :
        h('section', { class: 'card' }, dataTable({ caption: 'سابقهٔ فعالیت شرکت', rows: data.items, rowKey: (item) => item.id,
          columns: [
            { header: 'زمان', cell: (item) => formatDateTime(item.created_at) },
            { header: 'انجام‌دهنده', cell: (item) => item.user?.full_name ?? 'سامانه' },
            { header: 'عملیات', cell: (item) => actionLabel(item.action) },
            { header: 'محموله', cell: (item) => item.entity_type === 'shipment' ? h('a', { href: `#/shipments/${item.entity_id}` }, 'مشاهدهٔ محموله') : '—' },
          ],
        }), paginationBar(data.pagination, (page) => ctx.setQuery({ page }))))
    : asyncBlock(ctx, () => loadAll(ctx, '/companies'), (companies) => h('section', { class: 'card card-body stack' },
      companies.length ? companies.map((company) => h('a', { href: `#/company-activity?company_id=${company.id}` }, company.name)) : 'هنوز شرکتی ثبت نشده است.'));
  return { title: 'سابقهٔ فعالیت شرکت', element: h('div', {}, pageHeader({ title: 'سابقهٔ فعالیت شرکت', description: 'چه کسی، چه کاری و در چه زمانی انجام داده است.' }), block.element) };
}
