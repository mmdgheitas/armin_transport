import { h, icon } from '../core/dom.js';
import { formatDateTime, formatNumber } from '../core/format.js';
import { emptyBlock } from '../ui/feedback.js';
import { pageHeader } from '../ui/layout.js';
import { dataTable, shipmentStatusBadge, trackingCode } from '../ui/table.js';
import { asyncBlock } from './shared.js';

function stat(iconName, tone, value, label) {
  return h(
    'div',
    { class: 'card stat' },
    h('div', { class: `stat-icon ${tone}`.trim() }, icon(iconName, { size: 22 })),
    h('div', {}, h('div', { class: 'stat-value' }, formatNumber(value)), h('div', { class: 'stat-label' }, label)),
  );
}

export function recentShipmentsTable(shipments, { showCompany }) {
  return dataTable({
    caption: 'آخرین محموله‌ها',
    rowKey: (shipment) => shipment.id,
    rows: shipments,
    columns: [
      { header: 'کد رهگیری', cell: (shipment) => h('a', { class: 'row-link', href: `#/shipments/${shipment.id}` }, trackingCode(shipment.tracking_code)) },
      { header: 'توضیحات', className: 'truncate', cell: (shipment) => shipment.description ?? '—' },
      ...(showCompany ? [{ header: 'شرکت', cell: (shipment) => shipment.company?.name ?? '—' }] : []),
      { header: 'وضعیت', cell: (shipment) => shipmentStatusBadge(shipment.status) },
      { header: 'تاریخ ثبت', className: 'nowrap', cell: (shipment) => formatDateTime(shipment.created_at) },
    ],
  });
}

export function dashboardPage(ctx) {
  const canCreate = ctx.session.can('shipment:create');
  const block = asyncBlock(
    ctx,
    async (signal) => (await ctx.api.get('/dashboard/summary', { signal })).data,
    (summary) =>
      h(
        'div',
        { class: 'stack' },
        h(
          'div',
          { class: summary.companies || summary.employees ? 'stats cols-3' : 'stats' },
          stat('package', '', summary.shipments.total, 'کل محموله‌ها'),
          stat('truck', 'green', summary.shipments.active, 'محموله‌های فعال'),
          stat('archive', 'amber', summary.shipments.archived, 'محموله‌های بایگانی‌شده'),
          stat('file', 'slate', summary.documents, 'سندهای بارگذاری‌شده'),
          summary.companies && stat('briefcase', '', summary.companies.active, `شرکت فعال از ${formatNumber(summary.companies.total)} شرکت`),
          summary.employees && stat('users', 'green', summary.employees.active, `کارمند فعال از ${formatNumber(summary.employees.total)} کارمند`),
        ),
        h(
          'section',
          { class: 'card' },
          h('div', { class: 'card-header' }, h('h2', {}, 'آخرین محموله‌ها'), h('a', { class: 'btn btn-secondary btn-sm', href: '#/shipments' }, 'مشاهدهٔ همه')),
          summary.recent_shipments.length > 0
            ? recentShipmentsTable(summary.recent_shipments, { showCompany: summary.scope === 'GLOBAL' })
            : emptyBlock({
                iconName: 'package',
                title: 'هنوز محموله‌ای ثبت نشده است.',
                action: canCreate ? h('a', { class: 'btn', href: '#/shipments/new' }, icon('plus', { size: 16 }), 'ثبت محمولهٔ جدید') : null,
              }),
        ),
      ),
  );

  const user = ctx.session.user;
  return {
    title: 'داشبورد',
    element: h(
      'div',
      {},
      pageHeader({
        title: `${user?.full_name ?? ''}، خوش آمدید`,
        description: user?.company?.name ? `خلاصهٔ وضعیت ${user.company.name}` : 'خلاصهٔ وضعیت همهٔ شرکت‌ها',
        actions: canCreate ? [h('a', { class: 'btn', href: '#/shipments/new' }, icon('plus', { size: 16 }), 'ثبت محمولهٔ جدید')] : [],
      }),
      block.element,
    ),
  };
}
