import { h, icon, ltr } from '../core/dom.js';
import { formatDateTime, toPersianDigits } from '../core/format.js';
import { openModal } from '../ui/dialog.js';
import { alertBox, emptyBlock, toast } from '../ui/feedback.js';
import { buildForm, checkboxField, filterPanel, passwordField, requiredProblems, selectField, textField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { activeBadge, badge, dataTable, iconButton, paginationBar, roleLabel } from '../ui/table.js';
import { asyncBlock, companyOptions, loadAll, loadListPage } from './shared.js';

export function usersPage(ctx) {
  const { api, query, session } = ctx;
  const minPassword = session.appSettings.password?.min_length ?? 10;
  const passwordHint = `دست‌کم ${toPersianDigits(minPassword)} نویسه؛ نباید شامل نام کاربری باشد.`;
  const companiesPromise = loadAll(ctx, '/companies');
  companiesPromise.catch(() => {}); // failures are reported where the list is needed

  function userForm({ user = null, companies, close }) {
    const isNew = user === null;
    const canSetActive = isNew || session.can('user:set_active');
    const fields = {
      full_name: textField({ label: 'نام و نام خانوادگی', value: user?.full_name ?? '', required: true, maxlength: 200 }),
      username: textField({
        label: 'نام کاربری',
        value: user?.username ?? '',
        required: true,
        dir: 'ltr',
        maxlength: 100,
        hint: 'حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط؛ دست‌کم ۳ نویسه.',
      }),
      role: selectField({ label: 'نوع حساب', value: user?.role ?? 'EMPLOYEE', options: [{ value: 'EMPLOYEE', label: 'کارمند' }, { value: 'CUSTOMER', label: 'مشتری' }] }),
      company_id: selectField({ label: 'شرکت', value: user?.company_id ?? query.company_id ?? '', required: true, placeholder: 'انتخاب کنید', options: companyOptions(companies) }),
      ...(isNew ? { password: passwordField({ label: 'رمز عبور اولیه', autocomplete: 'new-password', hint: passwordHint }) } : {}),
      is_active: checkboxField({ label: 'حساب کاربری فعال است', checked: user?.is_active ?? true, hint: 'با غیرفعال شدن حساب، همهٔ نشست‌های کاربر بسته می‌شود.' }),
    };
    if (!canSetActive) delete fields.is_active;
    return buildForm({
      fields,
      submitLabel: isNew ? 'ایجاد کارمند' : 'ذخیرهٔ تغییرات',
      cancelLabel: 'انصراف',
      onCancel: close,
      validate: (values) =>
        requiredProblems(values, {
          full_name: 'نام را وارد کنید.',
          username: 'نام کاربری را وارد کنید.',
          company_id: 'شرکت را انتخاب کنید.',
          ...(isNew ? { password: 'رمز عبور را وارد کنید.' } : {}),
        }),
      async onSubmit(values) {
        const payload = { ...(!user ? { role: values.role } : {}), full_name: values.full_name.trim(), username: values.username.trim(), company_id: values.company_id };
        if (canSetActive) payload.is_active = values.is_active;
        if (isNew) payload.password = values.password;
        const { message } = isNew ? await api.post('/users', { json: payload }) : await api.patch(`/users/${user.id}`, { json: payload });
        toast.success(message);
        close();
        ctx.reload();
      },
    });
  }

  async function openUserModal(user = null) {
    const body = h('div', {}, h('p', { class: 'muted' }, 'در حال دریافت فهرست شرکت‌ها…'));
    const modal = openModal({ title: user ? `ویرایش ${user.full_name}` : 'کارمند جدید', content: body });
    try {
      const companies = await companiesPromise;
      if (companies.length === 0) {
        body.replaceChildren(alertBox('warning', 'ابتدا باید دست‌کم یک شرکت تعریف کنید. ', h('a', { href: '#/companies', onClick: () => modal.close() }, 'مدیریت شرکت‌ها')));
        return;
      }
      const form = userForm({ user, companies, close: modal.close });
      body.replaceChildren(form.element);
      form.fields.full_name.focus();
    } catch {
      body.replaceChildren(alertBox('danger', 'فهرست شرکت‌ها دریافت نشد. صفحه را دوباره بارگذاری کنید.'));
    }
  }

  function openResetPassword(user) {
    const body = h('div');
    const modal = openModal({ title: 'بازنشانی رمز عبور', content: body });
    const newPassword = passwordField({ label: 'رمز عبور جدید', autocomplete: 'new-password', hint: passwordHint });
    const form = buildForm({
      fields: { new_password: newPassword },
      layout: [alertBox('warning', `با تغییر رمز، همهٔ نشست‌های فعال «${user.full_name}» بسته می‌شود و باید با رمز جدید وارد شود.`), newPassword.element],
      submitLabel: 'تغییر رمز عبور',
      submitIcon: 'key',
      cancelLabel: 'انصراف',
      onCancel: modal.close,
      validate: (values) => requiredProblems(values, { new_password: 'رمز عبور جدید را وارد کنید.' }),
      async onSubmit(values) {
        const { message } = await api.post(`/users/${user.id}/reset-password`, { json: { new_password: values.new_password } });
        toast.success(message);
        modal.close();
      },
    });
    body.append(form.element);
    newPassword.focus();
  }

  const fields = {
    q: textField({ label: 'جست‌وجو', value: query.q ?? '', placeholder: 'نام یا نام کاربری', maxlength: 100, className: 'wide' }),
    company_id: selectField({ label: 'شرکت', value: '', placeholder: 'همهٔ شرکت‌ها', options: [] }),
    role: selectField({
      label: 'نقش',
      value: query.role ?? '',
      placeholder: 'همه',
      options: [
        { value: 'EMPLOYEE', label: 'کارمند' },
        { value: 'SUPER_ADMIN', label: 'مدیر مرکزی' },
      ],
    }),
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
  companiesPromise
    .then((companies) => {
      const select = fields.company_id.control;
      for (const option of companyOptions(companies)) select.append(h('option', { value: option.value }, option.label));
      select.value = query.company_id ?? '';
    })
    .catch(() => {});
  const filters = buildForm({
    fields,
    submitLabel: 'اعمال فیلتر',
    submitIcon: 'search',
    submitClass: 'btn btn-secondary',
    actionsClass: 'row',
    onSubmit: async (values) => ctx.setQuery({ ...values, q: values.q.trim(), page: null }),
  });

  const list = asyncBlock(
    ctx,
    (signal) => loadListPage(ctx, '/users', { q: query.q, company_id: query.company_id, role: query.role, is_active: query.is_active }, signal),
    (data) =>
      data.items.length === 0
        ? emptyBlock({ iconName: 'users', title: 'کاربری با این مشخصات پیدا نشد.' })
        : h(
            'div',
            {},
            dataTable({
              caption: 'فهرست کاربران',
              rowKey: (user) => user.id,
              rows: data.items,
              columns: [
                { header: 'نام', cell: (user) => h('strong', {}, user.full_name) },
                { header: 'نام کاربری', cell: (user) => ltr(user.username, 'code') },
                { header: 'نقش', cell: (user) => (user.role === 'SUPER_ADMIN' ? badge(roleLabel(user.role), 'info') : roleLabel(user.role)) },
                { header: 'شرکت', cell: (user) => user.company?.name ?? '—' },
                { header: 'وضعیت', cell: (user) => activeBadge(user.is_active) },
                { header: 'آخرین ورود', className: 'nowrap hide-mobile', cell: (user) => (user.last_login_at ? formatDateTime(user.last_login_at) : 'هنوز وارد نشده') },
                {
                  header: h('span', { class: 'sr-only' }, 'عملیات'),
                  cell: (user) =>
                    // Administrator accounts are managed from the server command line, never through the web.
                    user.role === 'SUPER_ADMIN'
                      ? ''
                      : h(
                          'div',
                          { class: 'actions' },
                          session.can('user:reset_password') && iconButton({ iconName: 'key', label: `بازنشانی رمز ${user.full_name}`, onClick: () => openResetPassword(user) }),
                          session.can('user:update') && iconButton({ iconName: 'edit', label: `ویرایش ${user.full_name}`, onClick: () => openUserModal(user) }),
                        ),
                },
              ],
            }),
            paginationBar(data.pagination, (page) => ctx.setQuery({ page })),
          ),
  );

  return {
    title: 'کاربران',
    element: h(
      'div',
      {},
      pageHeader({
        title: 'کاربران',
        description: 'کارمندان شرکت‌ها. هر کارمند فقط به محموله‌های شرکت خود دسترسی دارد.',
        actions: session.can('user:create') ? [h('button', { type: 'button', class: 'btn', onClick: () => openUserModal() }, icon('plus', { size: 16 }), 'کارمند جدید')] : [],
      }),
      h('section', { class: 'card' }, filterPanel(filters, { active: Boolean(query.q || query.company_id || query.role || query.is_active) }), list.element),
    ),
  };
}
