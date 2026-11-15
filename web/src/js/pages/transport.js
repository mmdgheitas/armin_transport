/** Transport workspace: role-specific home, manual codes and country-scoped file slots. */
import { h, icon, saveBlob } from '../core/dom.js';
import { formatNumber } from '../core/format.js';
import { openModal } from '../ui/dialog.js';
import { emptyBlock, errorMessage, toast, withBusyButton } from '../ui/feedback.js';
import { buildForm, textField, passwordField, selectField, multiCheckField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { paginationBar } from '../ui/table.js';
import { asyncBlock, loadAll, loadListPage } from './shared.js';

export const COUNTRIES = ['CI', 'KZ', 'UZ'];
const isAdmin = (ctx) => ctx.session.user?.role === 'SUPER_ADMIN';
const countryOptions = COUNTRIES.map((value) => ({ value, label: value }));
const link = (href, label) => h('a', { class: 'btn', href }, label);

function modalForm(ctx, title, fields, path, payload = (values) => values, after = ctx.reload, layout = null) {
  const modal = openModal({ title, content: h('div'), size: 'lg' });
  const form = buildForm({ fields, ...(layout ? { layout } : {}), submitLabel: 'ثبت', cancelLabel: 'انصراف', onCancel: modal.close,
    async onSubmit(values) {
      const { message } = await ctx.api.post(path, { json: payload(values) });
      toast.success(message); modal.close(); after();
    },
  });
  modal.dialog.querySelector('.modal-body').replaceChildren(form.element);
  return form;
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
  const list = asyncBlock(ctx, (signal) => loadListPage(ctx, '/transport/companies', { q: ctx.query.q }, signal),
    (data) => h('div', {}, data.items.length ? h('div', { class: 'company-grid' }, data.items.map((company) =>
      h('a', { class: 'company-tile', href: `#/companies/${company.id}` }, icon('briefcase', { size: 36 }), h('h2', {}, company.name), h('span', {}, 'مشاهدهٔ بارها'))))
      : emptyBlock({ iconName: 'briefcase', title: 'شرکتی ثبت نشده است.' }), paginationBar(data.pagination, (page) => ctx.setQuery({ page }))));
  return { title: 'لیست شرکت‌ها', element: h('div', { class: 'stack' }, pageHeader({ title: management ? 'لیست شرکت‌ها' : 'ترانسپورت کنترل',
    actions: management && isAdmin(ctx) ? [h('button', { class: 'btn', onClick: () => modalForm(ctx, 'ثبت شرکت', { name: textField({ label: 'اسم شرکت', required: true, maxlength: 200, hint: '۱ تا ۲۰۰ نویسه' }) }, '/transport/companies') }, 'ثبت شرکت')] : [] }), search(ctx, 'نام شرکت'), list.element) };
}

export function transportEmployees(ctx) {
  const create = () => modalForm(ctx, 'تعریف کارمند', {
    full_name: textField({ label: 'اسم کامل', required: true, maxlength: 200, hint: '۱ تا ۲۰۰ نویسه' }),
    username: textField({ label: 'یوزرنیم', required: true, dir: 'ltr', maxlength: 100, hint: '۳ تا ۱۰۰ نویسه؛ حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط' }),
    password: passwordField({ label: 'پسورد', autocomplete: 'new-password', hint: `${ctx.session.appSettings.password?.min_length ?? 10} تا ۱۲۸ نویسه؛ نباید شامل یوزرنیم باشد.` }),
    country: selectField({ label: 'کشور', required: true, placeholder: 'انتخاب کشور', options: countryOptions }),
  }, '/transport/employees');
  const list = asyncBlock(ctx, (signal) => loadListPage(ctx, '/transport/employees', { q: ctx.query.q }, signal), (data) =>
    h('section', { class: 'card card-body stack' }, data.items.map((employee) => h('div', { class: 'employee-row' }, h('strong', {}, employee.full_name), h('bdi', {}, employee.username), h('span', { class: 'country-label' }, employee.country))),
      !data.items.length && h('p', {}, 'کارمندی ثبت نشده است.'), paginationBar(data.pagination, (page) => ctx.setQuery({ page }))));
  return { title: 'مدیریت کارمند', element: h('div', { class: 'stack' }, pageHeader({ title: 'مدیریت کارمند', actions: [h('button', { class: 'btn', onClick: create }, 'تعریف کارمند')] }), search(ctx, 'اسم کارمند'), list.element) };
}

async function newShipment(ctx, companyId) {
  try {
    const employees = await loadAll(ctx, '/transport/employees');
    const countries = multiCheckField({ label: 'کشورهای بار', options: countryOptions, required: true });
    const choices = employees.map((employee) => ({ employee, input: h('input', { type: 'checkbox', value: employee.id, disabled: true }) }));
    const employeeField = h('fieldset', { class: 'card card-body' }, h('legend', {}, 'تخصیص کارمند'), choices.map(({ employee, input }) =>
      h('label', { class: 'check' }, input, `${employee.full_name} · ${employee.country}`)));
    const update = () => {
      const active = countries.getValue();
      for (const { employee, input } of choices) { input.disabled = !active.includes(employee.country); if (input.disabled) input.checked = false; }
    };
    countries.control.addEventListener('change', update);
    const fields = {
      tracking_code: textField({ label: 'کد یکتای بار (دستی)', required: true, multiline: true, hint: 'متن عیناً ذخیره می‌شود؛ بزرگی حروف و فاصله‌ها متفاوت‌اند.' }),
      countries,
      upload_limit: textField({ label: 'تعداد فایل مجاز برای هر کارمند', type: 'number', required: true }),
      truck_count: textField({ label: 'تعداد کامیون', type: 'number', required: true }),
      border_count: textField({ label: 'تعداد مرز', type: 'number', required: true }),
    };
    for (const key of ['upload_limit', 'truck_count', 'border_count']) { fields[key].control.min = key === 'border_count' ? '0' : '1'; fields[key].control.step = '1'; }
    modalForm(ctx, 'تعریف محموله', fields, '/transport/shipments', (values) => ({ ...values, company_id: companyId,
      upload_limit: Number(values.upload_limit), truck_count: Number(values.truck_count), border_count: Number(values.border_count),
      employee_ids: choices.filter(({ input }) => input.checked && !input.disabled).map(({ employee }) => employee.id),
    }), ctx.reload, [...Object.values(fields).map((field) => field.element), employeeField]);
  } catch (error) { toast.error(errorMessage(error)); }
}

export function transportShipments(ctx) {
  const companyId = ctx.params.companyId;
  const admin = isAdmin(ctx);
  // No global "all shipments" entry: admins enter through a company.
  if (admin && !companyId) return transportCompanies({ ...ctx, path: '/transport' });
  const block = asyncBlock(ctx, async (signal) => {
    const data = await loadListPage(ctx, '/transport/shipments', { company_id: companyId, q: ctx.query.q }, signal);
    const company = admin ? (await loadAll(ctx, '/transport/companies')).find((item) => item.id === companyId) : null;
    return { ...data, company };
  }, (data) => h('div', { class: 'stack' },
    data.company && pageHeader({ title: data.company.name, actions: [
      h('button', { class: 'btn', onClick: () => newShipment(ctx, companyId) }, 'تعریف محموله'),
      data.company.account_username ? h('span', { class: 'country-label' }, `حساب شرکت: ${data.company.account_username}`) :
        h('button', { class: 'btn btn-secondary', onClick: () => modalForm(ctx, 'تعریف حساب ورود شرکت', {
          username: textField({ label: 'یوزرنیم شرکت', required: true, dir: 'ltr', maxlength: 100, hint: '۳ تا ۱۰۰ نویسه؛ حروف انگلیسی، رقم، نقطه، خط تیره و زیرخط' }), password: passwordField({ label: 'پسورد شرکت', autocomplete: 'new-password', hint: `${ctx.session.appSettings.password?.min_length ?? 10} تا ۱۲۸ نویسه؛ نباید شامل یوزرنیم باشد.` }),
        }, `/transport/companies/${companyId}/account`) }, 'تعریف حساب شرکت'),
    ] }),
    data.items.length ? h('div', { class: 'shipment-grid' }, data.items.map((item) => h('a', { class: 'shipment-tile', href: `#/loads/${item.id}` },
      h('strong', { class: 'exact-code' }, item.tracking_code), h('span', {}, item.company_name),
      h('div', { class: 'row' }, item.countries.map((country) => h('span', { class: 'country-label' }, country))),
      h('span', {}, `${formatNumber(item.truck_count)} کامیون · ${formatNumber(item.border_count)} مرز`)))) : emptyBlock({ iconName: 'truck', title: 'باری برای نمایش وجود ندارد.' }),
    paginationBar(data.pagination, (page) => ctx.setQuery({ page }))));
  return { title: admin ? 'بارهای شرکت' : 'بارهای من', element: h('div', { class: 'stack' }, !admin && pageHeader({ title: 'بارهای من' }), search(ctx, 'جست‌وجوی کد بار'), block.element) };
}

function fileTile(ctx, file) {
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
  return button;
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
          h('div', { class: 'file-grid' }, group.files.map((file) => fileTile(ctx, file)),
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
    return h('div', { class: 'stack' }, pageHeader({ title: data.company_name, actions: [link(isAdmin(ctx) ? `#/companies/${data.company_id}` : '#/dashboard', 'بازگشت'), ...(isAdmin(ctx) ? [h('button', { class: 'btn btn-secondary', onClick: change }, 'ویرایش کد')] : [])] }),
      h('h2', { class: 'exact-code' }, data.tracking_code), h('p', {}, `${formatNumber(data.truck_count)} کامیون · ${formatNumber(data.border_count)} مرز`), tabs, body);
  });
  return { title: 'فایل‌های بار', element: block.element };
}
