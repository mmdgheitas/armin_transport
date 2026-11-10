import { h, icon, ltr } from '../core/dom.js';
import { RULE_DEFINITIONS, buildOptions, buildValidationRules, describeRules, ruleValueToInput } from '../core/fields.js';
import { FIELD_TYPE_LABELS, formatNumber, toLatinDigits } from '../core/format.js';
import { openModal } from '../ui/dialog.js';
import { alertBox, emptyBlock, toast } from '../ui/feedback.js';
import { buildForm, checkboxField, filterPanel, jalaliDateField, requiredProblems, selectField, textField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { activeBadge, badge, dataTable, iconButton, paginationBar } from '../ui/table.js';
import { asyncBlock, loadListPage } from './shared.js';

const OPTION_TYPES = new Set(['SELECT', 'MULTI_SELECT']);
const FIELD_KEY_PATTERN = /^[a-z][a-z0-9_]{1,99}$/;
const PATTERN_HINT = 'مقدار باید به‌طور کامل با الگو منطبق باشد. تکرار تودرتو، انتخاب (|) درون تکرار و ارجاع به گروه پذیرفته نمی‌شود.';

/** Editor for the `validation_rules` of a field; the set of controls follows the data type. */
function rulesEditor(initialType, initialRules) {
  const grid = h('div', { class: 'form-grid' });
  const error = h('div', { class: 'field-error', role: 'alert', hidden: true });
  const element = h('div', { class: 'stack-sm' }, h('h3', {}, 'قواعد اعتبارسنجی'), h('p', { class: 'field-hint' }, 'همهٔ قواعد اختیاری‌اند؛ موارد خالی اعمال نمی‌شوند.'), grid, error);
  let type = initialType;
  let controls = {};

  function build(rules) {
    controls = {};
    const definitions = RULE_DEFINITIONS[type] ?? [];
    for (const { key, label, kind } of definitions) {
      const value = ruleValueToInput(kind, rules?.[key]);
      if (kind === 'date') controls[key] = jalaliDateField({ label, value });
      else if (kind === 'datetime') controls[key] = jalaliDateField({ label, value, withTime: true });
      else if (kind === 'text') controls[key] = textField({ label, value, dir: 'ltr', inputClass: 'code', maxlength: 200, hint: PATTERN_HINT, className: 'span-all' });
      else controls[key] = textField({ label, value, dir: 'ltr', inputmode: kind === 'integer' ? 'numeric' : 'decimal', maxlength: 40 });
    }
    grid.replaceChildren(...Object.values(controls).map((control) => control.element));
    element.hidden = definitions.length === 0;
  }
  build(initialRules);

  return {
    element,
    setType(next) {
      type = next;
      build(null);
    },
    /** `{ rules }` or `{ errors }`; errors are also shown next to their controls. */
    getValue() {
      const result = buildValidationRules(type, Object.fromEntries(Object.entries(controls).map(([key, control]) => [key, control.getValue()])));
      for (const [key, control] of Object.entries(controls)) control.setError(result.errors?.[key] ?? null);
      return result;
    },
    setError(message) {
      error.textContent = message ?? '';
      error.hidden = !message;
    },
    focus: () => Object.values(controls)[0]?.focus(),
  };
}

/** Editor for the options of SELECT / MULTI_SELECT fields. */
function optionsEditor(initialType, initialOptions) {
  const rows = [];
  const list = h('div', { class: 'stack-sm' });
  const error = h('div', { class: 'field-error', role: 'alert', hidden: true });
  const add = h('button', { type: 'button', class: 'btn btn-secondary btn-sm' }, icon('plus', { size: 16 }), 'افزودن گزینه');
  const element = h(
    'div',
    { class: 'stack-sm' },
    h('h3', {}, 'گزینه‌ها'),
    h('p', { class: 'field-hint' }, '«مقدار» شناسهٔ ثابتی است که ذخیره می‌شود (بهتر است انگلیسی و کوتاه باشد) و «برچسب» متنی است که کاربران می‌بینند.'),
    list,
    h('div', {}, add),
    error,
  );

  function addRow(option = { value: '', label: '' }, { focus = false } = {}) {
    const value = h('input', { class: 'input code', type: 'text', dir: 'ltr', maxlength: 100, placeholder: 'value', 'aria-label': 'مقدار گزینه', autocomplete: 'off', value: option.value });
    const label = h('input', { class: 'input', type: 'text', maxlength: 200, placeholder: 'برچسب', 'aria-label': 'برچسب گزینه', autocomplete: 'off', value: option.label });
    const row = { value, label };
    row.element = h(
      'div',
      { class: 'option-row' },
      value,
      label,
      iconButton({
        iconName: 'trash',
        label: 'حذف گزینه',
        onClick: () => {
          rows.splice(rows.indexOf(row), 1);
          row.element.remove();
        },
      }),
    );
    rows.push(row);
    list.append(row.element);
    if (focus) value.focus();
  }

  for (const option of initialOptions ?? []) addRow(option);
  if (rows.length === 0) addRow();
  add.addEventListener('click', () => addRow(undefined, { focus: true }));
  element.hidden = !OPTION_TYPES.has(initialType);

  return {
    element,
    setType(next) {
      element.hidden = !OPTION_TYPES.has(next);
    },
    /** `{ options }` or `{ error }`. */
    getValue: () => buildOptions(rows.map((row) => ({ value: row.value.value, label: row.label.value }))),
    setError(message) {
      error.textContent = message ?? '';
      error.hidden = !message;
    },
    focus: () => rows[0]?.value.focus(),
  };
}

function fieldForm({ api, field = null, onSaved, close }) {
  const isNew = field === null;
  const initialType = field?.data_type ?? 'TEXT';
  const rules = rulesEditor(initialType, field?.validation_rules ?? null);
  const options = optionsEditor(initialType, field?.options ?? null);
  const fields = {
    label: textField({ label: 'برچسب', value: field?.label ?? '', required: true, maxlength: 200, hint: 'عنوانی که در فرم‌ها و برای مشتری نمایش داده می‌شود.' }),
    field_key: textField({
      label: 'کلید فیلد',
      value: field?.field_key ?? '',
      required: true,
      dir: 'ltr',
      inputClass: 'code',
      maxlength: 100,
      hint: isNew ? 'حروف کوچک انگلیسی، رقم و زیرخط؛ مثلاً weight_kg. پس از ایجاد قابل تغییر نیست.' : 'کلید فیلد قابل تغییر نیست.',
    }),
    data_type: selectField({
      label: 'نوع داده',
      value: initialType,
      required: true,
      options: Object.entries(FIELD_TYPE_LABELS).map(([value, label]) => ({ value, label })),
      hint: isNew ? 'پس از ایجاد قابل تغییر نیست.' : 'نوع داده قابل تغییر نیست؛ در صورت نیاز این فیلد را غیرفعال و فیلد تازه‌ای تعریف کنید.',
    }),
    display_order: textField({ label: 'ترتیب نمایش', value: String(field?.display_order ?? 0), dir: 'ltr', inputmode: 'numeric', maxlength: 6, hint: 'فیلدها به ترتیب صعودی این عدد نمایش داده می‌شوند.' }),
    is_required: checkboxField({ label: 'وارد کردن این فیلد الزامی است', checked: field?.is_required ?? false }),
    is_customer_visible: checkboxField({ label: 'به مشتری نمایش داده شود', checked: field?.is_customer_visible ?? false, hint: 'مشتری مقدار این فیلد را در صفحهٔ رهگیری می‌بیند.' }),
    is_active: checkboxField({ label: 'فیلد فعال است', checked: field?.is_active ?? true, hint: 'فیلد غیرفعال در فرم‌ها نمایش داده نمی‌شود، ولی مقادیر ثبت‌شدهٔ قبلی حفظ می‌شوند.' }),
    validation_rules: rules,
    options,
  };
  if (!isNew) {
    fields.field_key.control.disabled = true;
    fields.data_type.control.disabled = true;
  } else {
    fields.data_type.control.addEventListener('change', () => {
      rules.setType(fields.data_type.getValue());
      options.setType(fields.data_type.getValue());
    });
  }

  return buildForm({
    fields,
    layout: [
      !isNew && alertBox('info', 'تغییر برچسب، الزامی بودن، قواعد یا گزینه‌ها نسخهٔ فیلد را افزایش می‌دهد و مقادیر ثبت‌شدهٔ قبلی با نشان «نیازمند بازبینی» مشخص می‌شوند.'),
      h('div', { class: 'form-grid' }, fields.label.element, fields.field_key.element, fields.data_type.element, fields.display_order.element),
      h('div', { class: 'form-grid' }, fields.is_required.element, fields.is_customer_visible.element, fields.is_active.element),
      options.element,
      rules.element,
    ].filter(Boolean),
    submitLabel: isNew ? 'تعریف فیلد' : 'ذخیرهٔ تغییرات',
    cancelLabel: 'انصراف',
    onCancel: close,
    validate(values) {
      const problems = requiredProblems(values, { label: 'برچسب را وارد کنید.', field_key: 'کلید فیلد را وارد کنید.' });
      if (isNew && !problems.field_key && !FIELD_KEY_PATTERN.test(values.field_key.trim())) {
        problems.field_key = 'کلید باید با حرف کوچک انگلیسی شروع شود و فقط شامل حروف کوچک، رقم و زیرخط باشد (۲ تا ۱۰۰ نویسه).';
      }
      const order = toLatinDigits(values.display_order).trim();
      if (!/^\d{1,6}$/.test(order) || Number(order) > 100000) problems.display_order = 'عددی بین ۰ و ۱۰۰٬۰۰۰ وارد کنید.';
      if (OPTION_TYPES.has(values.data_type) && values.options.error) problems.options = values.options.error;
      if (values.validation_rules.errors) problems.validation_rules = 'قواعد مشخص‌شده را اصلاح کنید.';
      return problems;
    },
    async onSubmit(values) {
      const payload = {
        label: values.label.trim(),
        is_required: values.is_required,
        is_customer_visible: values.is_customer_visible,
        is_active: values.is_active,
        display_order: Number(toLatinDigits(values.display_order).trim()),
        validation_rules: values.validation_rules.rules,
        options: OPTION_TYPES.has(values.data_type) ? values.options.options : null,
      };
      if (isNew) {
        payload.field_key = values.field_key.trim();
        payload.data_type = values.data_type;
      }
      const { message } = isNew ? await api.post('/product-fields', { json: payload }) : await api.patch(`/product-fields/${field.id}`, { json: payload });
      toast.success(message);
      close();
      onSaved();
    },
  });
}

export function productFieldsPage(ctx) {
  const { api, query } = ctx;
  const onlyActive = query.active === '1';

  function openFieldModal(field = null) {
    const body = h('div');
    const modal = openModal({ title: field ? `ویرایش فیلد «${field.label}»` : 'فیلد جدید', content: body, size: 'lg' });
    const form = fieldForm({ api, field, onSaved: ctx.reload, close: modal.close });
    body.append(form.element);
    form.fields.label.focus();
  }

  const fields = {
    q: textField({ label: 'جست‌وجو', value: query.q ?? '', placeholder: 'برچسب یا کلید فیلد', maxlength: 100, className: 'wide' }),
    active: selectField({
      label: 'وضعیت',
      value: onlyActive ? '1' : '',
      options: [
        { value: '', label: 'همهٔ فیلدها' },
        { value: '1', label: 'فقط فعال' },
      ],
    }),
  };
  const filters = buildForm({
    fields,
    submitLabel: 'اعمال فیلتر',
    submitIcon: 'search',
    submitClass: 'btn btn-secondary',
    actionsClass: 'row',
    onSubmit: async (values) => ctx.setQuery({ q: values.q.trim(), active: values.active, page: null }),
  });

  const list = asyncBlock(
    ctx,
    (signal) => loadListPage(ctx, '/product-fields', { q: query.q, include_inactive: onlyActive ? 'false' : 'true' }, signal),
    (data) =>
      data.items.length === 0
        ? emptyBlock({
            iconName: 'sliders',
            title: query.q || onlyActive ? 'فیلدی با این مشخصات پیدا نشد.' : 'هنوز فیلدی تعریف نشده است.',
            text: query.q || onlyActive ? null : 'با تعریف فیلد، مشخصاتی مانند وزن، تعداد یا نوع بسته‌بندی به فرم محموله‌ها افزوده می‌شود.',
          })
        : h(
            'div',
            {},
            dataTable({
              caption: 'فیلدهای محموله',
              rowKey: (field) => field.id,
              rows: data.items,
              columns: [
                { header: 'ترتیب', cell: (field) => formatNumber(field.display_order) },
                {
                  header: 'برچسب',
                  cell: (field) => h('div', {}, h('strong', {}, field.label), describeRules(field) && h('div', { class: 'small muted' }, describeRules(field))),
                },
                { header: 'کلید', cell: (field) => ltr(field.field_key, 'code') },
                {
                  header: 'نوع',
                  className: 'nowrap',
                  cell: (field) => (OPTION_TYPES.has(field.data_type) ? `${FIELD_TYPE_LABELS[field.data_type]} (${formatNumber(field.options?.length ?? 0)} گزینه)` : (FIELD_TYPE_LABELS[field.data_type] ?? field.data_type)),
                },
                { header: 'الزامی', className: 'hide-mobile', cell: (field) => (field.is_required ? badge('الزامی', 'warning') : 'اختیاری') },
                { header: 'نمایش به مشتری', className: 'hide-mobile', cell: (field) => (field.is_customer_visible ? badge('قابل مشاهده', 'success') : badge('پنهان')) },
                { header: 'وضعیت', cell: (field) => activeBadge(field.is_active) },
                {
                  header: h('span', { class: 'sr-only' }, 'عملیات'),
                  cell: (field) => h('div', { class: 'actions' }, iconButton({ iconName: 'edit', label: `ویرایش فیلد ${field.label}`, onClick: () => openFieldModal(field) })),
                },
              ],
            }),
            paginationBar(data.pagination, (page) => ctx.setQuery({ page })),
          ),
  );

  return {
    title: 'فیلدهای محموله',
    element: h(
      'div',
      {},
      pageHeader({
        title: 'فیلدهای محموله',
        description: 'مشخصات دلخواهی که برای هر محموله ثبت می‌شود. این تعریف‌ها بین همهٔ شرکت‌ها مشترک است.',
        actions: [h('button', { type: 'button', class: 'btn', onClick: () => openFieldModal() }, icon('plus', { size: 16 }), 'فیلد جدید')],
      }),
      h('section', { class: 'card' }, filterPanel(filters, { active: Boolean(query.q || onlyActive) }), list.element),
    ),
  };
}
