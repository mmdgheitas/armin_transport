import { ApiError, isAbortError } from '../core/api.js';
import { copyText, h, icon, ltr, mount, saveBlob } from '../core/dom.js';
import { collectFieldValues, fieldErrorsFromApi } from '../core/fields.js';
import { formatDateTime, formatFieldValue, formatFileSize, formatNumber } from '../core/format.js';
import { normalizeTrackingCode, trackingCodeProblem } from '../core/tracking.js';
import { confirmAndRun, openModal } from '../ui/dialog.js';
import { alertBox, emptyBlock, errorBlock, errorMessage, loadingBlock, toast, withBusyButton } from '../ui/feedback.js';
import { buildForm, checkboxField, textField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { badge, dataTable, iconButton, keyValueList, paginationBar, shipmentStatusBadge, trackingCode, trackingCodeTypeLabel } from '../ui/table.js';
import { asyncBlock, productFieldControl, readProductControls, showProductErrors } from './shared.js';

const TABS = [
  { id: 'details', label: 'مشخصات کالا', permission: 'product_value:view' },
  { id: 'documents', label: 'سندها', permission: 'document:view' },
  { id: 'history', label: 'تاریخچهٔ کد رهگیری', permission: 'tracking_code:history' },
];

export function shipmentDetailPage(ctx) {
  const { api, session } = ctx;
  const shipmentPath = `/shipments/${encodeURIComponent(ctx.params.id)}`;
  const can = (permission) => session.can(permission);

  // ------------------------------------------------------------------ header actions
  function editDescription(shipment, reload) {
    const body = h('div');
    const modal = openModal({ title: 'ویرایش توضیحات', content: body });
    const form = buildForm({
      fields: { description: textField({ label: 'توضیحات', multiline: true, rows: 5, maxlength: 5000, value: shipment.description ?? '' }) },
      cancelLabel: 'انصراف',
      onCancel: modal.close,
      async onSubmit(values) {
        const { message } = await api.patch(shipmentPath, { json: { description: values.description.trim() === '' ? null : values.description.trim() } });
        toast.success(message);
        modal.close();
        reload();
      },
    });
    body.append(form.element);
    form.fields.description.focus();
  }

  function changeTrackingCode(shipment, reload) {
    const manualAllowed = can('tracking_code:manual');
    const body = h('div');
    const modal = openModal({ title: 'تغییر کد رهگیری', content: body });
    const code = textField({
      label: 'کد رهگیری جدید',
      dir: 'ltr',
      inputClass: 'code',
      maxlength: 200,
      hint: manualAllowed ? 'برای تولید خودکار کد جدید، این فیلد را خالی بگذارید.' : null,
    });
    const form = buildForm({
      fields: manualAllowed ? { tracking_code: code } : {},
      layout: [
        alertBox(
          'warning',
          'با تغییر کد، کد فعلی برای همیشه از کار می‌افتد، دسترسی مشتریانی که با آن وارد شده‌اند لغو می‌شود و کد قدیمی دیگر قابل استفاده نیست.',
        ),
        h('p', {}, 'کد فعلی: ', trackingCode(shipment.tracking_code)),
        manualAllowed && code.element,
      ].filter(Boolean),
      submitLabel: manualAllowed ? 'تغییر کد' : 'تولید کد جدید',
      submitIcon: 'refresh',
      cancelLabel: 'انصراف',
      onCancel: modal.close,
      validate(values) {
        if (!manualAllowed) return {};
        const normalized = normalizeTrackingCode(values.tracking_code);
        code.setValue(normalized);
        const problem = normalized === '' ? null : trackingCodeProblem(normalized, session.appSettings.tracking_code);
        return problem ? { tracking_code: problem } : {};
      },
      async onSubmit(values) {
        const manual = manualAllowed ? normalizeTrackingCode(values.tracking_code) : '';
        const { message } = await api.post(`${shipmentPath}/tracking-code`, { json: manual === '' ? { generate: true } : { tracking_code: manual } });
        toast.success(message);
        modal.close();
        reload();
      },
    });
    body.append(form.element);
    if (manualAllowed) code.focus();
  }

  function headerCard(shipment, reload) {
    const archived = shipment.status === 'ARCHIVED';
    const copy = iconButton({
      iconName: 'copy',
      label: 'کپی کد رهگیری',
      onClick: async () => (await copyText(shipment.tracking_code)) ? toast.success('کد رهگیری کپی شد.') : toast.error('کپی کردن ممکن نشد؛ کد را دستی انتخاب کنید.'),
    });

    const actions = [];
    if (!archived && can('shipment:update')) {
      actions.push(h('button', { type: 'button', class: 'btn btn-secondary btn-sm', onClick: () => editDescription(shipment, reload) }, icon('edit', { size: 16 }), 'ویرایش توضیحات'));
    }
    if (!archived && can('tracking_code:change')) {
      actions.push(h('button', { type: 'button', class: 'btn btn-secondary btn-sm', onClick: () => changeTrackingCode(shipment, reload) }, icon('refresh', { size: 16 }), 'تغییر کد رهگیری'));
    }
    if (can('customer_session:revoke')) {
      const revoke = h('button', { type: 'button', class: 'btn btn-secondary btn-sm' }, icon('ban', { size: 16 }), 'لغو دسترسی مشتریان');
      revoke.addEventListener('click', () =>
        confirmAndRun({
          button: revoke,
          confirm: {
            title: 'لغو دسترسی مشتریان',
            message: 'همهٔ نشست‌های فعال مشتریان برای این محموله بسته می‌شود. مشتری با وارد کردن دوبارهٔ کد رهگیری می‌تواند وارد شود.',
            confirmLabel: 'لغو دسترسی‌ها',
          },
          action: () => api.post(`${shipmentPath}/customer-sessions/revoke`),
        }),
      );
      actions.push(revoke);
    }
    if (!archived && can('shipment:archive')) {
      const archive = h('button', { type: 'button', class: 'btn btn-danger-outline btn-sm' }, icon('archive', { size: 16 }), 'بایگانی');
      archive.addEventListener('click', () =>
        confirmAndRun({
          button: archive,
          confirm: {
            title: 'بایگانی محموله',
            message: 'محمولهٔ بایگانی‌شده فقط قابل مشاهده است و دیگر نمی‌توان آن را ویرایش کرد یا سندی به آن افزود. ادامه می‌دهید؟',
            confirmLabel: 'بایگانی شود',
            danger: true,
          },
          action: () => api.post(`${shipmentPath}/archive`),
          onDone: reload,
        }),
      );
      actions.push(archive);
    }
    if (archived && can('shipment:unarchive')) {
      const restore = h('button', { type: 'button', class: 'btn btn-secondary btn-sm' }, icon('restore', { size: 16 }), 'خروج از بایگانی');
      restore.addEventListener('click', () => confirmAndRun({ button: restore, action: () => api.post(`${shipmentPath}/unarchive`), onDone: reload }));
      actions.push(restore);
    }

    return h(
      'section',
      { class: 'card' },
      h(
        'div',
        { class: 'card-body stack' },
        h(
          'div',
          { class: 'row-between' },
          h('div', { class: 'row' }, h('span', { class: 'tracking-code' }, ltr(shipment.tracking_code), copy), shipmentStatusBadge(shipment.status), badge(`کد ${trackingCodeTypeLabel(shipment.tracking_code_type)}`)),
          actions.length > 0 && h('div', { class: 'row' }, actions),
        ),
        archived && alertBox('warning', 'این محموله بایگانی شده است و فقط می‌توان آن را مشاهده و سندهایش را دریافت کرد.'),
        keyValueList([
          ['شرکت', shipment.company?.name ?? '—'],
          ['ثبت‌کننده', shipment.created_by?.full_name ?? '—'],
          ['تاریخ ثبت', formatDateTime(shipment.created_at, { style: 'long' })],
          ['آخرین تغییر', formatDateTime(shipment.updated_at, { style: 'long' })],
          ['تعداد سندها', formatNumber(shipment.document_count)],
          ['توضیحات', shipment.description ?? '—'],
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ product values
  function detailsTab(shipment) {
    const host = h('div');
    const editable = shipment.status !== 'ARCHIVED' && can('product_value:edit');

    function showValues(items) {
      const visible = items.filter((item) => item.field.is_active || item.value !== null);
      if (visible.length === 0) {
        mount(host, emptyBlock({ iconName: 'sliders', title: 'فیلدی برای مشخصات کالا تعریف نشده است.' }));
        return;
      }
      mount(
        host,
        h(
          'div',
          { class: 'card-body stack' },
          editable &&
            items.some((item) => item.field.is_active) &&
            h('div', { class: 'row-between' }, h('span', { class: 'muted small' }, 'مقادیر ثبت‌شده برای این محموله'), h('button', { type: 'button', class: 'btn btn-secondary btn-sm', onClick: () => showForm(items) }, icon('edit', { size: 16 }), 'ویرایش مشخصات')),
          keyValueList(
            visible.map((item) => [
              h(
                'span',
                {},
                item.field.label,
                !item.field.is_active && h('span', {}, ' ', badge('فیلد غیرفعال')),
                item.is_outdated && h('span', {}, ' ', badge('نیازمند بازبینی', 'warning')),
              ),
              formatFieldValue(item.field.data_type, item.display_value),
            ]),
          ),
        ),
      );
    }

    function showForm(items) {
      const fields = items.filter((item) => item.field.is_active).map((item) => item.field);
      const current = Object.fromEntries(items.map((item) => [item.field.field_key, item.value]));
      const controls = Object.fromEntries(fields.map((field) => [field.field_key, productFieldControl(field, current[field.field_key])]));
      const formError = h('div', { hidden: true });
      const submit = h('button', { type: 'submit', class: 'btn' }, icon('check', { size: 16 }), 'ذخیرهٔ مشخصات');
      const form = h(
        'form',
        { class: 'card-body form', novalidate: true },
        h('div', { class: 'form-grid' }, fields.map((field) => controls[field.field_key].element)),
        formError,
        h('div', { class: 'form-actions' }, h('button', { type: 'button', class: 'btn btn-secondary', onClick: () => showValues(items) }, 'انصراف'), submit),
      );
      form.addEventListener('submit', (event) => {
        event.preventDefault();
        formError.hidden = true;
        const { inputs, errors: dateErrors } = readProductControls(controls);
        const { values, errors: valueErrors } = collectFieldValues(
          fields.filter((field) => !(field.field_key in dateErrors)),
          inputs,
        );
        if (showProductErrors(controls, { ...valueErrors, ...dateErrors })) return;
        withBusyButton(submit, async () => {
          try {
            const { data, message } = await api.put(`${shipmentPath}/product-values`, { json: { values } });
            toast.success(message);
            showValues(data.items);
          } catch (error) {
            const mapped = showProductErrors(controls, fieldErrorsFromApi(error instanceof ApiError ? error.fields : {}));
            if (!mapped || !(error instanceof ApiError) || !error.isValidation) {
              formError.replaceChildren(alertBox('danger', errorMessage(error)));
              formError.hidden = false;
            }
          }
        });
      });
      mount(host, form);
    }

    async function load() {
      mount(host, loadingBlock());
      try {
        const { data } = await api.get(`${shipmentPath}/product-values`, { signal: ctx.signal });
        if (!ctx.signal.aborted) showValues(data.items);
      } catch (error) {
        if (!isAbortError(error) && !ctx.signal.aborted) mount(host, errorBlock(error, load));
      }
    }
    load();
    return host;
  }

  // ------------------------------------------------------------------ documents
  function uploadPanel(onUploaded) {
    const settings = session.appSettings.upload ?? {};
    const maxFiles = settings.max_files_per_upload ?? 12;
    const maxSize = settings.max_file_size_bytes ?? 10 * 1024 * 1024;
    const allowed = settings.allowed_extensions ?? [];
    let selected = []; // [{ file, error }]

    const input = h('input', { type: 'file', multiple: true, hidden: true, accept: allowed.map((extension) => `.${extension}`).join(',') || null });
    const list = h('ul', { class: 'file-list' });
    const summary = h('div', { hidden: true });
    const visible = checkboxField({
      label: 'مشتری بتواند این سندها را با کد رهگیری ببیند',
      checked: settings.customer_visible_default ?? true,
    });
    const submit = h('button', { type: 'button', class: 'btn', disabled: true }, icon('upload', { size: 16 }), 'بارگذاری');
    const dropzone = h(
      'button',
      { type: 'button', class: 'dropzone', onClick: () => input.click() },
      icon('upload', { size: 26 }),
      h('strong', {}, 'فایل‌ها را اینجا رها کنید یا برای انتخاب کلیک کنید'),
      h('span', { class: 'small' }, `حداکثر ${formatNumber(maxFiles)} فایل، بدون محدودیت نوع و حجم`, allowed.length > 0 ? ` · قالب‌های مجاز: ${allowed.join('، ')}` : ''),
    );

    const localProblem = (file) => {
      const extension = file.name.includes('.') ? file.name.split('.').pop().toLowerCase() : '';
      if (allowed.length > 0 && !allowed.includes(extension)) return 'قالب این فایل مجاز نیست.';
      if (file.size === 0) return 'فایل خالی است.';
      if (maxSize && file.size > maxSize) return `حجم فایل بیشتر از ${formatFileSize(maxSize)} است.`;
      return null;
    };

    function renderSelection(message = null) {
      list.replaceChildren(
        ...selected.map((entry, index) =>
          h(
            'li',
            { class: entry.error ? 'has-error' : null },
            icon('file', { size: 18 }),
            h('div', { class: 'grow' }, h('div', { class: 'file-name' }, ltr(entry.file.name)), h('div', { class: 'small muted' }, formatFileSize(entry.file.size)), entry.error && h('div', { class: 'field-error' }, entry.error)),
            iconButton({
              iconName: 'x',
              label: `حذف ${entry.file.name} از فهرست`,
              onClick: () => {
                selected.splice(index, 1);
                renderSelection();
              },
            }),
          ),
        ),
      );
      const tooMany = selected.length > maxFiles;
      const problem = message ?? (tooMany ? `در هر بار حداکثر ${formatNumber(maxFiles)} فایل قابل بارگذاری است.` : null);
      summary.replaceChildren(...(problem ? [alertBox('danger', problem)] : []));
      summary.hidden = !problem;
      submit.disabled = selected.length === 0 || tooMany || selected.some((entry) => entry.error);
      submit.replaceChildren(icon('upload', { size: 16 }), selected.length > 0 ? `بارگذاری ${formatNumber(selected.length)} فایل` : 'بارگذاری');
    }

    function addFiles(files) {
      for (const file of files) {
        if (!selected.some((entry) => entry.file.name === file.name && entry.file.size === file.size)) selected.push({ file, error: localProblem(file) });
      }
      renderSelection();
    }

    input.addEventListener('change', () => {
      addFiles(input.files);
      input.value = '';
    });
    for (const type of ['dragenter', 'dragover']) {
      dropzone.addEventListener(type, (event) => {
        event.preventDefault();
        dropzone.classList.add('is-dragging');
      });
    }
    for (const type of ['dragleave', 'drop']) {
      dropzone.addEventListener(type, (event) => {
        event.preventDefault();
        dropzone.classList.remove('is-dragging');
      });
    }
    dropzone.addEventListener('drop', (event) => addFiles(event.dataTransfer?.files ?? []));

    submit.addEventListener('click', () =>
      withBusyButton(submit, async () => {
        const formData = new FormData();
        for (const entry of selected) formData.append('files', entry.file, entry.file.name);
        formData.append('customer_visible', visible.getValue() ? 'true' : 'false');
        try {
          const { message } = await api.post(`${shipmentPath}/documents`, { formData });
          toast.success(message);
          selected = [];
          renderSelection();
          onUploaded();
        } catch (error) {
          let matched = false;
          if (error instanceof ApiError) {
            for (const [name, messages] of Object.entries(error.fields)) {
              const index = /^files\.(\d+)$/.exec(name)?.[1];
              if (index !== undefined && selected[Number(index)]) {
                selected[Number(index)].error = messages.join(' ');
                matched = true;
              }
            }
            const tooLarge = error.details?.file_index;
            if (Number.isInteger(tooLarge) && selected[tooLarge]) {
              selected[tooLarge].error = error.message;
              matched = true;
            }
          }
          renderSelection(matched ? 'هیچ فایلی بارگذاری نشد. فایل‌های مشخص‌شده را اصلاح یا حذف کنید و دوباره تلاش کنید.' : errorMessage(error));
        }
      }),
    );

    return h('div', { class: 'card-body stack' }, input, dropzone, list, summary, h('div', { class: 'row-between' }, submit));
  }

  function documentsTab(shipment, reloadShipment) {
    const archived = shipment.status === 'ARCHIVED';
    const listHost = h('div');

    async function download(button, item) {
      await withBusyButton(button, async () => {
        try {
          const file = await api.download(`/documents/${item.id}/download`);
          saveBlob(file.blob, file.filename === 'download' ? item.original_name : file.filename);
        } catch (error) {
          toast.error(errorMessage(error));
        }
      });
    }

    async function load(page = 1) {
      mount(listHost, loadingBlock());
      try {
        const { data } = await api.get(`${shipmentPath}/documents`, { query: { page, per_page: 20 }, signal: ctx.signal });
        if (ctx.signal.aborted) return;
        if (data.items.length === 0) {
          mount(listHost, emptyBlock({ iconName: 'file', title: 'هنوز سندی برای این محموله بارگذاری نشده است.' }));
          return;
        }
        mount(
          listHost,
          dataTable({
            caption: 'سندهای محموله',
            rowKey: (item) => item.id,
            rows: data.items,
            columns: [
              {
                header: 'نام فایل',
                cell: (item) => h('div', {}, h('div', { class: 'file-name' }, ltr(item.original_name)), h('div', { class: 'small muted' }, formatFileSize(item.file_size))),
              },
              { header: 'بارگذاری‌کننده', className: 'hide-mobile', cell: (item) => item.uploaded_by?.full_name ?? '—' },
              { header: 'تاریخ', className: 'nowrap hide-mobile', cell: (item) => formatDateTime(item.created_at) },
              {
                header: h('span', { class: 'sr-only' }, 'عملیات'),
                cell(item) {
                  const downloadButton = iconButton({ iconName: 'download', label: `دریافت ${item.original_name}`, onClick: () => download(downloadButton, item) });
                  const buttons = [can('document:download') && downloadButton];
                  if (!archived && can('document:delete')) {
                    const remove = iconButton({
                      iconName: 'trash',
                      label: `حذف ${item.original_name}`,
                      onClick: () =>
                        confirmAndRun({
                          button: remove,
                          confirm: { title: 'حذف سند', message: `سند «${item.original_name}» برای همیشه حذف می‌شود. ادامه می‌دهید؟`, confirmLabel: 'حذف شود', danger: true },
                          action: () => api.delete(`/documents/${item.id}`),
                          onDone: reloadShipment,
                        }),
                    });
                    buttons.push(remove);
                  }
                  return h('div', { class: 'actions' }, buttons);
                },
              },
            ],
          }),
          data.pagination.total_pages > 1 && paginationBar(data.pagination, load),
        );
      } catch (error) {
        if (!isAbortError(error) && !ctx.signal.aborted) mount(listHost, errorBlock(error, () => load(page)));
      }
    }
    load();

    return h('div', {}, !archived && can('document:upload') && uploadPanel(reloadShipment), listHost);
  }

  // ------------------------------------------------------------------ tracking history
  function historyTab() {
    const host = h('div');
    async function load(page = 1) {
      mount(host, loadingBlock());
      try {
        const { data } = await api.get(`${shipmentPath}/tracking-history`, { query: { page, per_page: 20 }, signal: ctx.signal });
        if (ctx.signal.aborted) return;
        mount(
          host,
          data.items.length === 0
            ? emptyBlock({ iconName: 'clock', title: 'تغییری در کد رهگیری ثبت نشده است.' })
            : h(
                'div',
                {},
                dataTable({
                  caption: 'تاریخچهٔ کد رهگیری',
                  rows: data.items,
                  columns: [
                    { header: 'کد قبلی', cell: (entry) => (entry.old_code ? trackingCode(entry.old_code) : '— (ثبت اولیه)') },
                    { header: 'کد جدید', cell: (entry) => trackingCode(entry.new_code) },
                    { header: 'تغییردهنده', cell: (entry) => entry.changed_by?.full_name ?? '—' },
                    { header: 'زمان', className: 'nowrap', cell: (entry) => formatDateTime(entry.changed_at) },
                  ],
                }),
                data.pagination.total_pages > 1 && paginationBar(data.pagination, load),
              ),
        );
      } catch (error) {
        if (!isAbortError(error) && !ctx.signal.aborted) mount(host, errorBlock(error, () => load(page)));
      }
    }
    load();
    return host;
  }

  // ------------------------------------------------------------------ page
  function tabsCard(shipment, reload) {
    const tabs = TABS.filter((tab) => can(tab.permission));
    if (tabs.length === 0) return null;
    const panel = h('div', { role: 'tabpanel' });
    const buttons = new Map();
    const builders = {
      details: () => detailsTab(shipment),
      documents: () => documentsTab(shipment, reload),
      history: () => historyTab(),
    };

    function select(id, { remember = true } = {}) {
      for (const [tabId, button] of buttons) button.setAttribute('aria-selected', String(tabId === id));
      mount(panel, builders[id]());
      if (remember) ctx.rememberQuery({ tab: id === tabs[0].id ? null : id });
    }

    const bar = h(
      'div',
      { class: 'tabs', role: 'tablist' },
      tabs.map((tab) => {
        const label = tab.id === 'documents' ? `${tab.label} (${formatNumber(shipment.document_count)})` : tab.label;
        const button = h('button', { type: 'button', class: 'tab', role: 'tab', 'aria-selected': 'false', onClick: () => select(tab.id) }, label);
        buttons.set(tab.id, button);
        return button;
      }),
    );
    // Read from the live address: after a reload of the block the previously selected tab stays open.
    const requested = ctx.liveQuery().tab;
    select(tabs.some((tab) => tab.id === requested) ? requested : tabs[0].id, { remember: false });
    return h('section', { class: 'card' }, bar, panel);
  }

  const block = asyncBlock(
    ctx,
    async (signal) => (await api.get(shipmentPath, { signal })).data,
    (shipment, reload) => h('div', { class: 'stack' }, headerCard(shipment, reload), tabsCard(shipment, reload)),
    { loadingText: 'در حال دریافت اطلاعات محموله…' },
  );

  return {
    title: 'جزئیات محموله',
    element: h(
      'div',
      {},
      pageHeader({
        title: 'جزئیات محموله',
        actions: [h('a', { class: 'btn btn-ghost', href: '#/shipments' }, icon('chevron-right', { size: 16 }), 'بازگشت به فهرست')],
      }),
      block.element,
    ),
  };
}
