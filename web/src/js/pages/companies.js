import { actionLabel } from './audit-logs.js';
import { h, icon, ltr } from '../core/dom.js';
import { formatDateTime, formatNumber } from '../core/format.js';
import { openModal } from '../ui/dialog.js';
import { alertBox, emptyBlock, toast } from '../ui/feedback.js';
import { buildForm, checkboxField, filterPanel, passwordField, requiredProblems, selectField, textField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { activeBadge, dataTable, iconButton, paginationBar } from '../ui/table.js';
import { asyncBlock, loadListPage } from './shared.js';

function companyForm({ api, session, company = null, onSaved, close }) {
  const isNew = company === null;
  const canSetActive = isNew || session.can('company:set_active');
  const fields = {
    ...(isNew ? {
      username: textField({ label: 'نام کاربری شرکت', required: true, dir: 'ltr', autocomplete: 'off', maxlength: 100 }),
      password: passwordField({ label: 'رمز عبور شرکت', autocomplete: 'new-password', hint: `رمز قوی با حداقل ${formatNumber(session.appSettings.password?.min_length ?? 10)} نویسه وارد کنید.` }),
    } : {}),
    name: textField({ label: 'نام شرکت', value: company?.name ?? '', required: true, maxlength: 200 }),
    company_code: textField({
      label: 'کد شرکت',
      value: company?.company_code ?? '',
      required: true,
      dir: 'ltr',
      inputClass: 'code',
      maxlength: 50,
      hint: 'شناسهٔ کوتاه و یکتا با حروف انگلیسی، رقم، خط تیره یا زیرخط (مثلاً ARMIN).',
    }),
    phone: textField({ label: 'تلفن', value: company?.phone ?? '', dir: 'ltr', maxlength: 30, inputmode: 'tel' }),
    address: textField({ label: 'نشانی', value: company?.address ?? '', multiline: true, maxlength: 2000 }),
    is_active: checkboxField({
      label: 'شرکت فعال است',
      checked: company?.is_active ?? true,
      hint: 'با غیرفعال شدن شرکت، ورود حساب شرکت مسدود می‌شود.',
    }),
  };
  if (!canSetActive) delete fields.is_active;
  return buildForm({
    fields,
    submitLabel: isNew ? 'ایجاد شرکت' : 'ذخیرهٔ تغییرات',
    cancelLabel: 'انصراف',
    onCancel: close,
    validate: (values) => requiredProblems(values, { name: 'نام شرکت را وارد کنید.', company_code: 'کد شرکت را وارد کنید.', ...(isNew ? { username: 'نام کاربری شرکت را وارد کنید.', password: 'رمز عبور شرکت را وارد کنید.' } : {}) }),
    async onSubmit(values) {
      const payload = {
        ...(isNew ? { username: values.username.trim(), password: values.password } : {}),
        name: values.name.trim(),
        company_code: values.company_code.trim(),
        phone: values.phone.trim() === '' ? null : values.phone.trim(),
        address: values.address.trim() === '' ? null : values.address.trim(),
        ...(canSetActive ? { is_active: values.is_active } : {}),
      };
      const { message } = isNew ? await api.post('/companies', { json: payload }) : await api.patch(`/companies/${company.id}`, { json: payload });
      toast.success(message);
      close();
      onSaved();
    },
  });
}

export function companiesPage(ctx) {
  const { api, query, session } = ctx;
  const canCreate = session.can('company:create');
  const canUpdate = session.can('company:update');

  function openCreate() {
    const modal = openModal({ title: 'شرکت جدید', content: h('div') });
    const form = companyForm({ api, session, onSaved: ctx.reload, close: modal.close });
    modal.dialog.querySelector('.modal-body').replaceChildren(form.element);
    form.fields.name.focus();
  }

  async function openEdit(company) {
    const body = h('div', { class: 'stack' });
    const modal = openModal({ title: `ویرایش ${company.name}`, content: body });
    const form = companyForm({ api, session, company, onSaved: ctx.reload, close: modal.close });
    body.append(form.element);
    try {
      const { data } = await api.get(`/companies/${company.id}`, { signal: ctx.signal });
      body.prepend(alertBox('info', `${formatNumber(data.shipment_count)} محموله برای این شرکت ثبت شده است. حساب شرکت از بخش کاربران قابل مدیریت است.`));
    } catch {
      // The counters are informational; the form works without them.
    }
  }

  const fields = {
    q: textField({ label: 'جست‌وجو', value: query.q ?? '', placeholder: 'نام یا کد شرکت', maxlength: 100, className: 'wide' }),
    is_active: selectField({
      label: 'وضعیت',
      value: query.is_active ?? '',
      placeholder: 'همه',
      options: [
        { value: 'true', label: 'فعال' },
        { value: 'false', label: 'غیرفعال' },
      ],
    }),
  };
  const filters = buildForm({
    fields,
    submitLabel: 'اعمال فیلتر',
    submitIcon: 'search',
    submitClass: 'btn btn-secondary',
    actionsClass: 'row',
    onSubmit: async (values) => ctx.setQuery({ q: values.q.trim(), is_active: values.is_active, page: null }),
  });

  const list = asyncBlock(
    ctx,
    (signal) => loadListPage(ctx, '/companies', { q: query.q, is_active: query.is_active }, signal),
    (data) =>
      data.items.length === 0
        ? emptyBlock({ iconName: 'briefcase', title: query.q || query.is_active ? 'شرکتی با این مشخصات پیدا نشد.' : 'هنوز شرکتی تعریف نشده است.' })
        : h(
            'div',
            {},
            dataTable({
              caption: 'فهرست شرکت‌ها',
              rowKey: (company) => company.id,
              rows: data.items,
              columns: [
                { header: 'نام شرکت', cell: (company) => h('a', { href: `#/shipments?company_id=${company.id}&status=ACTIVE` }, company.name) },
                { header: 'آخرین فعالیت', cell: (company) => company.last_activity ? `${actionLabel(company.last_activity.action)} · ${company.last_activity.user?.full_name ?? 'سامانه'} · ${formatDateTime(company.last_activity.created_at)}` : '—' },
                { header: 'کد', cell: (company) => ltr(company.company_code, 'code') },
                { header: 'تلفن', className: 'hide-mobile', cell: (company) => (company.phone ? ltr(company.phone) : '—') },
                { header: 'وضعیت', cell: (company) => activeBadge(company.is_active) },
                { header: 'تاریخ ایجاد', className: 'nowrap hide-mobile', cell: (company) => formatDateTime(company.created_at) },
                {
                  header: h('span', { class: 'sr-only' }, 'عملیات'),
                  cell: (company) =>
                    h(
                      'div',
                      { class: 'actions' },
                      // The caption is hidden on a phone, so the name is given explicitly; it also tells the links of the rows apart.
                      session.can('company_activity:view') && h(
                        'a',
                        { class: 'btn btn-ghost btn-sm', href: `#/company-activity?company_id=${company.id}`, 'aria-label': `سابقهٔ فعالیت ${company.name}`, title: `سابقهٔ فعالیت ${company.name}` },
                        icon('users', { size: 16 }),
                        h('span', { class: 'hide-mobile' }, 'سابقهٔ فعالیت'),
                      ),
                      canUpdate && iconButton({ iconName: 'edit', label: `ویرایش ${company.name}`, onClick: () => openEdit(company) }),
                    ),
                },
              ],
            }),
            paginationBar(data.pagination, (page) => ctx.setQuery({ page })),
          ),
  );

  return {
    title: 'شرکت‌ها',
    element: h(
      'div',
      {},
      pageHeader({
        title: 'شرکت‌ها',
        description: 'شرکت‌های حمل‌ونقلی که از سامانه استفاده می‌کنند. داده‌های هر شرکت از شرکت‌های دیگر جداست.',
        actions: canCreate ? [h('button', { type: 'button', class: 'btn', onClick: openCreate }, icon('plus', { size: 16 }), 'شرکت جدید')] : [],
      }),
      h('section', { class: 'card' }, filterPanel(filters, { active: Boolean(query.q || query.is_active) }), list.element),
    ),
  };
}
