/** Transport workspace: role-specific home, manual codes and country-scoped file slots. */
import { h, icon, saveBlob } from '../core/dom.js';
import { formatNumber } from '../core/format.js';
import { confirmDialog, openModal } from '../ui/dialog.js';
import { emptyBlock, errorMessage, toast, withBusyButton } from '../ui/feedback.js';
import { buildForm, textField, passwordField, selectField, multiCheckField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { paginationBar } from '../ui/table.js';
import { asyncBlock, loadAll, loadListPage } from './shared.js';

export const COUNTRIES = ['CI', 'KZ', 'UZ'];
const isAdmin = (ctx) => ctx.session.user?.role === 'SUPER_ADMIN';
const countryOptions = COUNTRIES.map((value) => ({ value, label: value }));
const link = (href, label) => h('a', { class: 'btn', href }, label);

function modalForm(ctx, title, fields, path, payload = (values) => values, after = ctx.reload, layout = null, method = 'post') {
  const modal = openModal({ title, content: h('div'), size: 'lg' });
  const form = buildForm({ fields, ...(layout ? { layout } : {}), submitLabel: 'ثبت', cancelLabel: 'انصراف', onCancel: modal.close,
    async onSubmit(values) {
      const { message } = await ctx.api[method](path, { json: payload(values) });
      toast.success(message); modal.close(); after();
    },
  });
  modal.dialog.querySelector('.modal-body').replaceChildren(form.element);
  return form;
}

function action(ctx, label, path, method = 'delete', after = ctx.reload) {
  const button = h('button', { type: 'button', class: 'btn btn-secondary' }, label);
  button.addEventListener('click', () => withBusyButton(button, async () => {
    if (!await confirmDialog({ title: label, message: method === 'delete' ? 'حذف نرم انجام شود؟ اطلاعات و فایل‌ها باقی می‌مانند و ادمین می‌تواند بازیابی کند.' : 'بازیابی انجام شود؟', confirmLabel: label })) return;
    try { await ctx.api[method](path); toast.success('انجام شد.'); after(); }
    catch (error) { toast.error(errorMessage(error)); }
  }));
  return button;
}

function trashToggle(ctx) {
  return isAdmin(ctx) && h('button', { class: 'btn btn-secondary', onClick: () => ctx.setQuery({ deleted: ctx.query.deleted === 'true' ? null : 'true', page: null }) }, ctx.query.deleted === 'true' ? 'نمایش فعال‌ها' : 'حذف‌شده‌ها / بازیابی');
}

function editCompany(ctx, company) {
  modalForm(ctx, 'ویرایش شرکت', { name: textField({ label: 'اسم شرکت', value: company.name, required: true, maxlength: 200, hint: '۱ تا ۲۰۰ نویسه' }) }, `/transport/companies/${company.id}`, undefined, ctx.reload, null, 'patch');
}

function editEmployee(ctx, employee) {
  modalForm(ctx, 'ویرایش کارمند', {
    full_name: textField({ label: 'اسم کامل', value: employee.full_name, required: true, maxlength: 200, hint: '۱ تا ۲۰۰ نویسه' }),
    username: textField({ label: 'یوزرنیم', value: employee.username, required: true, maxlength: 100, hint: '۳ تا ۱۰۰ نویسه؛ حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط' }),
    password: passwordField({ label: 'پسورد جدید (اختیاری)', required: false, autocomplete: 'new-password', hint: `${ctx.session.appSettings.password?.min_length ?? 10} تا ۱۲۸ نویسه؛ خالی یعنی بدون تغییر` }),
    country: selectField({ label: 'کشور', value: employee.country, options: countryOptions, required: true }),
  }, `/transport/employees/${employee.id}`, (values) => { if (!values.password) delete values.password; return values; }, ctx.reload, null, 'patch');
}

function accountActions(ctx, company) {
  const path = `/transport/companies/${company.id}/account`;
  if (company.account_deleted) return [action(ctx, 'بازیابی حساب شرکت', `${path}/restore`, 'post')];
  if (!company.account_username) return [];
  return [h('button', { class: 'btn btn-secondary', onClick: () => modalForm(ctx, 'ویرایش حساب شرکت', {
    username: textField({ label: 'یوزرنیم شرکت', value: company.account_username, maxlength: 100, required: true, hint: '۳ تا ۱۰۰ نویسه؛ حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط' }),
    password: passwordField({ label: 'پسورد جدید (اختیاری)', required: false, autocomplete: 'new-password', hint: `${ctx.session.appSettings.password?.min_length ?? 10} تا ۱۲۸ نویسه؛ خالی یعنی بدون تغییر` }),
  }, path, (values) => { if (!values.password) delete values.password; return values; }, ctx.reload, null, 'patch') }, 'ویرایش حساب / پسورد'), action(ctx, 'حذف حساب شرکت', path)];
}

function search(ctx, placeholder = 'جست‌وجو') {
  const q = textField({ label: 'جست‌وجو', placeholder, value: ctx.query.q ?? '' });
  return buildForm({ fields: { q }, submitLabel: 'جست‌وجو', onSubmit: async (values) => ctx.setQuery({ q: values.q, page: null }) }).element;
}

export function transportHome(ctx) {
  if (!isAdmin(ctx)) return transportShipments(ctx);
  return { title: 'کنترل ترانسپورت', element: h('div', { class: 'transport-home' },
    h('div', { class: 'transport-brand' }, icon('truck', { size: 54 }), h('h1', {}, 'کنترل ترانسپورت')),
    h('div', { class: 'launch-grid', 'aria-label': 'بخش‌های پنل مدیریت' },
      h('a', { href: '#/transport', class: 'launch-button' }, icon('truck', { size: 40 }), 'ترانسپورت کنترل'),
      ...[1, 2, 3, 4].map((index) => h('button', { type: 'button', class: 'launch-button reserved', disabled: true, 'aria-label': `بخش خالی ${index}` })))),
  };
}

export function transportCompanies(ctx) {
  const management = ctx.path === '/companies';
  const list = asyncBlock(ctx, (signal) => loadListPage(ctx, '/transport/companies', { q: ctx.query.q, deleted: ctx.query.deleted }, signal),
    (data) => h('div', {}, data.items.length ? h('div', { class: 'company-grid' }, data.items.map((company) =>
      h('section', { class: 'card card-body stack' }, company.deleted_at ? h('h2', {}, company.name) : h('a', { class: 'company-tile', href: `#/companies/${company.id}` }, icon('briefcase', { size: 36 }), h('h2', {}, company.name), h('span', {}, 'مشاهدهٔ بارها')), h('div', { class: 'row' }, company.deleted_at ? action(ctx, 'بازیابی شرکت', `/transport/companies/${company.id}/restore`, 'post') : [h('button', { class: 'btn btn-secondary', onClick: () => editCompany(ctx, company) }, 'ویرایش شرکت'), action(ctx, 'حذف شرکت', `/transport/companies/${company.id}`)]))))
      : emptyBlock({ iconName: 'briefcase', title: 'شرکتی ثبت نشده است.' }), paginationBar(data.pagination, (page) => ctx.setQuery({ page }))));
  return { title: 'لیست شرکت‌ها', element: h('div', { class: 'stack' }, pageHeader({ title: management ? 'لیست شرکت‌ها' : 'ترانسپورت کنترل',
    actions: management && isAdmin(ctx) ? [h('button', { class: 'btn', onClick: () => modalForm(ctx, 'ثبت شرکت', { name: textField({ label: 'اسم شرکت', required: true, maxlength: 200, hint: '۱ تا ۲۰۰ نویسه' }) }, '/transport/companies') }, 'ثبت شرکت')] : [] }), trashToggle(ctx), search(ctx, 'نام شرکت'), list.element) };
}

export function transportEmployees(ctx) {
  const create = () => modalForm(ctx, 'تعریف کارمند', {
    full_name: textField({ label: 'اسم کامل', required: true, maxlength: 200, hint: '۱ تا ۲۰۰ نویسه' }),
    username: textField({ label: 'یوزرنیم', required: true, dir: 'ltr', maxlength: 100, hint: '۳ تا ۱۰۰ نویسه؛ حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط' }),
    password: passwordField({ label: 'پسورد', autocomplete: 'new-password', hint: `${ctx.session.appSettings.password?.min_length ?? 10} تا ۱۲۸ نویسه؛ نباید شامل یوزرنیم باشد.` }),
    country: selectField({ label: 'کشور', required: true, placeholder: 'انتخاب کشور', options: countryOptions }),
  }, '/transport/employees');
  const list = asyncBlock(ctx, (signal) => loadListPage(ctx, '/transport/employees', { q: ctx.query.q, deleted: ctx.query.deleted }, signal), (data) =>
    h('section', { class: 'card card-body stack' }, data.items.map((employee) => h('div', { class: 'employee-row' }, h('strong', {}, employee.full_name), h('bdi', {}, employee.username), h('span', { class: 'country-label' }, employee.country), employee.deleted_at ? action(ctx, 'بازیابی کارمند', `/transport/employees/${employee.id}/restore`, 'post') : [h('button', { class: 'btn btn-secondary', onClick: () => editEmployee(ctx, employee) }, 'ویرایش / پسورد'), action(ctx, 'حذف کارمند', `/transport/employees/${employee.id}`)])),
      !data.items.length && h('p', {}, 'کارمندی ثبت نشده است.'), paginationBar(data.pagination, (page) => ctx.setQuery({ page }))));
  return { title: 'مدیریت کارمند', element: h('div', { class: 'stack' }, pageHeader({ title: 'مدیریت کارمند', actions: [h('button', { class: 'btn', onClick: create }, 'تعریف کارمند')] }), trashToggle(ctx), search(ctx, 'اسم کارمند'), list.element) };
}

async function newShipment(ctx, companyId, existing = null, after = ctx.reload) {
  try {
    const activeEmployees = await loadAll(ctx, '/transport/employees');
    const employees = [...activeEmployees, ...(existing?.employees ?? []).filter((employee) => !activeEmployees.some((item) => item.id === employee.id))];
    const countries = multiCheckField({ label: 'کشورهای بار', options: countryOptions, required: true, value: existing?.countries ?? [] });
    const choices = employees.map((employee) => ({ employee, input: h('input', { type: 'checkbox', value: employee.id, disabled: true, checked: existing?.employees.some((item) => item.id === employee.id) }) }));
    const employeeField = h('fieldset', { class: 'card card-body' }, h('legend', {}, 'تخصیص کارمند'), choices.map(({ employee, input }) =>
      h('label', { class: 'check' }, input, `${employee.full_name} · ${employee.country}`)));
    const update = () => {
      const active = countries.getValue();
      for (const { employee, input } of choices) { input.disabled = !active.includes(employee.country); if (input.disabled) input.checked = false; }
    };
    countries.control.addEventListener('change', update);
    update();
    const fields = {
      tracking_code: textField({ label: 'کد یکتای بار (دستی)', required: true, multiline: true, hint: 'متن عیناً ذخیره می‌شود؛ بزرگی حروف و فاصله‌ها متفاوت‌اند.' }),
      countries,
      upload_limit: textField({ label: 'تعداد فایل مجاز برای هر کارمند', type: 'number', required: true }),
      truck_count: textField({ label: 'تعداد کامیون', type: 'number', required: true }),
      border_count: textField({ label: 'تعداد مرز', type: 'number', required: true }),
    };
    for (const key of ['upload_limit', 'truck_count', 'border_count']) { fields[key].control.min = key === 'border_count' ? '0' : '1'; fields[key].control.step = '1'; }
    if (existing) for (const key of ['tracking_code', 'upload_limit', 'truck_count', 'border_count']) fields[key].setValue(existing[key]);
    modalForm(ctx, existing ? 'ویرایش محموله' : 'تعریف محموله', fields, existing ? `/transport/shipments/${existing.id}` : '/transport/shipments', (values) => ({ ...values, company_id: companyId,
      upload_limit: Number(values.upload_limit), truck_count: Number(values.truck_count), border_count: Number(values.border_count),
      employee_ids: choices.filter(({ input }) => input.checked && !input.disabled).map(({ employee }) => employee.id),
    }), after, [...Object.values(fields).map((field) => field.element), employeeField], existing ? 'patch' : 'post');
  } catch (error) { toast.error(errorMessage(error)); }
}

export function transportShipments(ctx) {
  const companyId = ctx.params.companyId;
  const admin = isAdmin(ctx);
  // No global "all shipments" entry: admins enter through a company.
  if (admin && !companyId) return transportCompanies({ ...ctx, path: '/transport' });
  const block = asyncBlock(ctx, async (signal) => {
    const data = await loadListPage(ctx, '/transport/shipments', { company_id: companyId, q: ctx.query.q, deleted: ctx.query.deleted }, signal);
    const company = admin ? (await ctx.api.get(`/transport/companies/${companyId}`, { signal })).data : null;
    return { ...data, company };
  }, (data) => h('div', { class: 'stack' },
    data.company && pageHeader({ title: data.company.name, actions: [
      ...accountActions(ctx, data.company),
      h('button', { class: 'btn', onClick: () => newShipment(ctx, companyId) }, 'تعریف محموله'),
      data.company.account_username ? h('span', { class: 'country-label' }, `حساب شرکت: ${data.company.account_username}`) :
        h('button', { class: 'btn btn-secondary', onClick: () => modalForm(ctx, 'تعریف حساب ورود شرکت', {
          username: textField({ label: 'یوزرنیم شرکت', required: true, dir: 'ltr', maxlength: 100, hint: '۳ تا ۱۰۰ نویسه؛ حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط' }), password: passwordField({ label: 'پسورد شرکت', autocomplete: 'new-password', hint: `${ctx.session.appSettings.password?.min_length ?? 10} تا ۱۲۸ نویسه؛ نباید شامل یوزرنیم باشد.` }),
        }, `/transport/companies/${companyId}/account`) }, 'تعریف حساب شرکت'),
    ] }),
    data.items.length ? h('div', { class: 'shipment-grid' }, data.items.map((item) => h('section', { class: 'shipment-tile' }, item.deleted_at ? h('h3', { class: 'exact-code' }, item.tracking_code) : link(`#/loads/${item.id}`, 'مشاهدهٔ بار'),
      h('strong', { class: 'exact-code' }, item.tracking_code), h('span', {}, item.company_name),
      h('div', { class: 'row' }, item.countries.map((country) => h('span', { class: 'country-label' }, country))),
      h('span', {}, `${formatNumber(item.truck_count)} کامیون · ${formatNumber(item.border_count)} مرز`), admin && (item.deleted_at ? action(ctx, 'بازیابی بار', `/transport/shipments/${item.id}/restore`, 'post') : action(ctx, 'حذف بار', `/transport/shipments/${item.id}`))))) : emptyBlock({ iconName: 'truck', title: 'باری برای نمایش وجود ندارد.' }),
    paginationBar(data.pagination, (page) => ctx.setQuery({ page }))));
  return { title: admin ? 'بارهای شرکت' : 'بارهای من', element: h('div', { class: 'stack' }, !admin && pageHeader({ title: 'بارهای من' }), trashToggle(ctx), search(ctx, 'جست‌وجوی کد بار'), block.element) };
}

function fileTile(ctx, file, canManage = false, reload = ctx.reload) {
  const preview = h('div', { class: 'file-preview' }, icon('file', { size: 30 }));
  const downloadPath = `/documents/${file.id}/download`;
  let objectUrl = null;
  const image = /\.(png|jpe?g|webp|gif|bmp)$/i.test(file.original_name);
  if (image) {
    const ext = file.original_name.split('.').pop().toLowerCase().replace('jpg', 'jpeg');
    ctx.api.download(downloadPath, { signal: ctx.signal }).then((result) => {
      if (ctx.signal.aborted || !preview.isConnected) return;
      objectUrl = URL.createObjectURL(new Blob([result.blob], { type: `image/${ext}` }));
      const img = h('img', { src: objectUrl, alt: file.original_name, loading: 'lazy' });
      preview.replaceChildren(img);
    }).catch(() => { /* The download control remains available if a preview is unsupported. */ });
  }
  ctx.signal.addEventListener('abort', () => { if (objectUrl) URL.revokeObjectURL(objectUrl); }, { once: true });
  const button = h('button', { class: 'file-slot filled', type: 'button', 'aria-label': `دانلود ${file.original_name}` }, preview, h('span', { class: 'file-name' }, file.original_name), h('span', {}, 'دانلود'));
  button.addEventListener('click', () => withBusyButton(button, async () => {
    try { const result = await ctx.api.download(downloadPath); saveBlob(result.blob, file.original_name); }
    catch (error) { toast.error(errorMessage(error)); }
  }));
  if (!canManage) return button;
  const replaceInput = h('input', { type: 'file', hidden: true });
  replaceInput.addEventListener('change', async () => {
    if (!replaceInput.files.length) return;
    replaceInput.disabled = true;
    try { const formData = new FormData(); formData.append('files', replaceInput.files[0]); await ctx.api.post(`/transport/files/${file.id}/replace`, { formData }); reload(); }
    catch (error) { toast.error(errorMessage(error)); } finally { replaceInput.disabled = false; replaceInput.value = ''; }
  });
  return h('div', { class: 'stack' }, button, replaceInput,
    h('button', { class: 'btn btn-secondary', onClick: () => modalForm(ctx, 'تغییر نام فایل', { original_name: textField({ label: 'نام فایل', value: file.original_name, required: true, maxlength: 255, hint: '۱ تا ۲۵۵ نویسه' }) }, `/transport/files/${file.id}`, undefined, reload, null, 'patch') }, 'تغییر نام'),
    h('button', { class: 'btn btn-secondary', onClick: () => replaceInput.click() }, 'جایگزینی فایل'),
    action(ctx, 'حذف فایل', `/transport/files/${file.id}`, 'delete', reload));
}

export function transportDetail(ctx) {
  const block = asyncBlock(ctx, async (signal) => (await ctx.api.get(`/transport/shipments/${ctx.params.id}`, { signal })).data, (data, reload) => {
    const employee = ctx.session.user?.role === 'EMPLOYEE';
    const ownCountry = ctx.session.user?.country;
    const countries = employee ? data.countries.filter((value) => value === ownCountry) : data.countries;
    let selected = countries.includes(ctx.query.tab) ? ctx.query.tab : countries[0];
    const body = h('div', { class: 'stack' });
    const tabs = h('div', { class: 'country-tabs', role: 'tablist', 'aria-label': 'کشورهای بار' });
    const render = () => {
      tabs.replaceChildren(...countries.map((country) => h('button', { type: 'button', role: 'tab', 'aria-selected': String(country === selected), class: `country-tab ${country === selected ? 'active' : ''}`,
        onClick: () => { selected = country; ctx.rememberQuery({ tab: country }); render(); } }, country)));
      const groups = data.groups.filter((group) => group.country === selected);
      body.replaceChildren(...groups.map((group) => {
        const input = h('input', { type: 'file', multiple: true, hidden: true });
        input.addEventListener('change', async () => {
          if (!input.files.length) return;
          const formData = new FormData(); for (const file of input.files) formData.append('files', file, file.name);
          formData.append('country', selected);
          input.disabled = true;
          try { await ctx.api.post(`/transport/shipments/${data.id}/files`, { formData }); toast.success('فایل بارگذاری شد.'); reload(); }
          catch (error) { toast.error(errorMessage(error)); } finally { input.disabled = false; input.value = ''; }
        });
        const spare = Math.max(0, group.limit - group.files.length);
        return h('section', { class: 'employee-files' }, h('h2', {}, `${group.full_name} : ${formatNumber(group.files.length)} فایل`),
          h('p', {}, `ظرفیت: ${formatNumber(group.limit)} فایل`), input,
          h('div', { class: 'file-grid' }, group.files.map((file) => fileTile(ctx, file, group.can_manage, reload)),
            Array.from({ length: spare }, (_, index) => h(group.can_upload ? 'button' : 'div', { class: 'file-slot empty', ...(group.can_upload ? { type: 'button', onClick: () => input.click(), 'aria-label': `آپلود فایل ${index + 1} برای ${group.full_name}` } : {}) }, group.can_upload ? icon('plus', { size: 32 }) : icon('file'), group.can_upload ? 'آپلود فایل' : 'بدون فایل'))));
      }), !groups.length && h('p', {}, 'هنوز کارمند یا فایلی برای این کشور ثبت نشده است.'));
    };
    render();
    const change = () => {
      const modal = openModal({ title: 'ویرایش کد بار', content: h('div') });
      const form = buildForm({ fields: { tracking_code: textField({ label: 'کد دستی و یکتا', multiline: true, value: data.tracking_code, required: true }) }, submitLabel: 'ذخیره',
        async onSubmit(values) { await ctx.api.patch(`/transport/shipments/${data.id}/code`, { json: values }); modal.close(); reload(); } });
      modal.dialog.querySelector('.modal-body').replaceChildren(form.element);
    };
    return h('div', { class: 'stack' }, pageHeader({ title: data.company_name, actions: [link(isAdmin(ctx) ? `#/companies/${data.company_id}` : '#/dashboard', 'بازگشت'), ...(isAdmin(ctx) ? [h('button', { class: 'btn btn-secondary', onClick: change }, 'ویرایش کد'), h('button', { class: 'btn', onClick: () => newShipment(ctx, data.company_id, data, reload) }, 'ویرایش بار / تخصیص‌ها'), action(ctx, 'حذف بار', `/transport/shipments/${data.id}`, 'delete', () => ctx.navigate(`#/companies/${data.company_id}`))] : [])] }),
      h('h2', { class: 'exact-code' }, data.tracking_code), h('p', {}, `${formatNumber(data.truck_count)} کامیون · ${formatNumber(data.border_count)} مرز`), tabs, body, isAdmin(ctx) && h('section', { class: 'stack' }, h('h2', {}, 'فایل‌های حذف‌شده'), (data.deleted_files ?? []).map((file) => h('div', { class: 'employee-row' }, h('span', {}, file.original_name), action(ctx, 'بازیابی فایل', `/transport/files/${file.id}/restore`, 'post', reload)))));
  });
  return { title: 'فایل‌های بار', element: block.element };
}
