/** Form controls with labels, hints and inline error messages. */

import { ApiError } from '../core/api.js';
import { h, icon } from '../core/dom.js';
import { toLatinDigits, toPersianDigits } from '../core/format.js';
import { JALALI_MONTH_NAMES, isoDateToJalali, jalaliToIsoDate } from '../core/jalali.js';
import { instantToLocalParts, localPartsToInstant } from '../core/fields.js';
import { alertBox, errorMessage, withBusyButton } from './feedback.js';

let nextId = 0;
const uniqueId = (prefix) => `${prefix}-${(nextId += 1)}`;

/** Shows or clears a validation message and tells assistive technology about it. */
function applyError(control, errorElement, message) {
  errorElement.textContent = message ?? '';
  errorElement.hidden = !message;
  if (message) control.setAttribute('aria-invalid', 'true');
  else control.removeAttribute('aria-invalid');
}

/**
 * Wraps a control with its label, hint and error slot. Returns `{ element, setError }`.
 * The hint and the error message are linked to the control (or control group) with aria-describedby.
 */
function fieldShell({ id, label, required = false, hint = null, control, className = '', labelFor = true }) {
  const error = h('div', { class: 'field-error', id: `${id}-error`, hidden: true });
  const hintElement = hint ? h('div', { class: 'field-hint', id: `${id}-hint` }, hint) : null;
  const labelElement = labelFor
    ? h('label', { for: id }, label, required && h('span', { class: 'required-mark', 'aria-hidden': 'true' }, '*'))
    : h('span', { class: 'field-label', id: `${id}-label` }, label, required && h('span', { class: 'required-mark', 'aria-hidden': 'true' }, '*'));
  control.setAttribute('aria-describedby', [hint ? `${id}-hint` : null, `${id}-error`].filter(Boolean).join(' '));
  const element = h('div', { class: `field ${className}`.trim() }, labelElement, control, hintElement, error);
  return {
    element,
    setError(message) {
      applyError(control, error, message);
      element.classList.toggle('has-error', Boolean(message));
    },
  };
}

export function textField({
  label,
  value = '',
  type = 'text',
  required = false,
  hint = null,
  dir = null,
  autocomplete = 'off',
  maxlength = null,
  placeholder = null,
  inputmode = null,
  className = '',
  inputClass = '',
  multiline = false,
  rows = 3,
}) {
  const id = uniqueId('field');
  const control = multiline
    ? h('textarea', { id, class: `textarea ${inputClass}`.trim(), rows, dir, maxlength, placeholder, required, value })
    : h('input', {
        id,
        class: `input ${inputClass}`.trim(),
        type,
        dir,
        autocomplete,
        maxlength,
        placeholder,
        inputmode,
        required,
        spellcheck: dir === 'ltr' ? 'false' : null,
        autocapitalize: dir === 'ltr' ? 'off' : null,
        value,
      });
  const shell = fieldShell({ id, label, required, hint, control, className });
  return {
    ...shell,
    control,
    getValue: () => control.value,
    setValue: (next) => {
      control.value = next ?? '';
    },
    focus: () => control.focus(),
  };
}

export function passwordField({ label, autocomplete = 'current-password', required = true, hint = null }) {
  const field = textField({ label, type: 'password', autocomplete, required, hint, dir: 'ltr', maxlength: 128 });
  const toggle = h(
    'button',
    {
      type: 'button',
      class: 'btn btn-secondary btn-icon',
      'aria-label': 'نمایش رمز عبور',
      'aria-pressed': 'false',
      onClick: () => {
        const reveal = field.control.type === 'password';
        field.control.type = reveal ? 'text' : 'password';
        toggle.setAttribute('aria-pressed', String(reveal));
        toggle.setAttribute('aria-label', reveal ? 'پنهان کردن رمز عبور' : 'نمایش رمز عبور');
        toggle.replaceChildren(icon(reveal ? 'eye-off' : 'eye'));
      },
    },
    icon('eye'),
  );
  const group = h('div', { class: 'input-group' });
  field.control.replaceWith(group);
  group.append(field.control, toggle);
  return field;
}

export function selectField({ label, options, value = '', required = false, hint = null, placeholder = null, className = '' }) {
  const id = uniqueId('field');
  const control = h(
    'select',
    { id, class: 'select', required, value },
    placeholder !== null && h('option', { value: '' }, placeholder),
    options.map((option) => h('option', { value: option.value }, option.label)),
  );
  const shell = fieldShell({ id, label, required, hint, control, className });
  return {
    ...shell,
    control,
    getValue: () => control.value,
    setValue: (next) => {
      control.value = next ?? '';
    },
    focus: () => control.focus(),
  };
}

export function checkboxField({ label, checked = false, hint = null, className = '' }) {
  const id = uniqueId('field');
  const control = h('input', { id, type: 'checkbox', checked, 'aria-describedby': [hint ? `${id}-hint` : null, `${id}-error`].filter(Boolean).join(' ') });
  const error = h('div', { class: 'field-error', id: `${id}-error`, hidden: true });
  const element = h(
    'div',
    { class: `field ${className}`.trim() },
    h('label', { class: 'check', for: id }, control, h('span', {}, label)),
    hint && h('div', { class: 'field-hint', id: `${id}-hint` }, hint),
    error,
  );
  return {
    element,
    control,
    getValue: () => control.checked,
    setValue: (next) => {
      control.checked = Boolean(next);
    },
    setError: (message) => applyError(control, error, message),
    focus: () => control.focus(),
  };
}

/** A group of check boxes; the value is the list of selected option values. */
export function multiCheckField({ label, options, value = [], required = false, hint = null, className = '' }) {
  const id = uniqueId('field');
  const selected = new Set(value);
  const boxes = options.map((option) => {
    const input = h('input', { type: 'checkbox', value: option.value, checked: selected.has(option.value) });
    return { input, element: h('label', { class: 'check' }, input, h('span', {}, option.label)) };
  });
  const control = h('div', { class: 'check-list', role: 'group', 'aria-labelledby': `${id}-label` }, boxes.map((box) => box.element));
  const shell = fieldShell({ id, label, required, hint, control, className, labelFor: false });
  return {
    ...shell,
    control,
    getValue: () => boxes.filter((box) => box.input.checked).map((box) => box.input.value),
    setValue: (next) => {
      const values = new Set(next ?? []);
      for (const box of boxes) box.input.checked = values.has(box.input.value);
    },
    focus: () => boxes[0]?.input.focus(),
  };
}

/**
 * Jalali date entry (day, month, year) with an optional time of day.
 * `getValue()` returns "" when empty, `null` when incomplete or impossible, otherwise
 * "YYYY-MM-DD" (Gregorian) or, with `withTime`, `{ date, time }`.
 */
export function jalaliDateField({ label, value = '', required = false, hint = null, withTime = false, className = '' }) {
  const id = uniqueId('field');
  const initial = withTime ? (value ?? { date: '', time: '' }) : { date: value ?? '', time: '' };
  const jalali = isoDateToJalali(initial.date);
  const day = h('input', {
    id,
    class: 'input',
    type: 'text',
    inputmode: 'numeric',
    maxlength: 2,
    placeholder: 'روز',
    'aria-label': `${label}: روز`,
    autocomplete: 'off',
    value: jalali ? toPersianDigits(jalali.jd) : '',
  });
  const month = h(
    'select',
    { class: 'select', 'aria-label': `${label}: ماه`, value: jalali ? String(jalali.jm) : '' },
    h('option', { value: '' }, 'ماه'),
    JALALI_MONTH_NAMES.map((name, index) => h('option', { value: String(index + 1) }, name)),
  );
  const year = h('input', {
    class: 'input',
    type: 'text',
    inputmode: 'numeric',
    maxlength: 4,
    placeholder: 'سال',
    'aria-label': `${label}: سال`,
    autocomplete: 'off',
    value: jalali ? toPersianDigits(jalali.jy) : '',
  });
  const time = withTime ? h('input', { class: 'input', type: 'time', dir: 'ltr', 'aria-label': `${label}: ساعت`, value: initial.time ?? '' }) : null;
  const control = h('div', { class: `date-input ${withTime ? 'with-time' : ''}`.trim(), role: 'group', 'aria-labelledby': `${id}-label` }, day, month, year, time);
  const shell = fieldShell({ id, label, required, hint, control, className: `date ${className}`.trim(), labelFor: false });

  const readDate = () => {
    const parts = [day.value, month.value, year.value].map((text) => toLatinDigits(text).trim());
    if (parts.every((text) => text === '')) return '';
    if (!parts.every((text) => /^\d+$/.test(text))) return null;
    return jalaliToIsoDate(Number(parts[2]), Number(parts[1]), Number(parts[0]));
  };

  return {
    ...shell,
    control,
    getValue() {
      const date = readDate();
      if (!withTime) return date;
      if (date === null) return null;
      if (date === '' && time.value === '') return '';
      return { date, time: time.value };
    },
    setValue(next) {
      const parts = withTime ? (next ?? { date: '', time: '' }) : { date: next ?? '', time: '' };
      const converted = isoDateToJalali(parts.date);
      day.value = converted ? toPersianDigits(converted.jd) : '';
      month.value = converted ? String(converted.jm) : '';
      year.value = converted ? toPersianDigits(converted.jy) : '';
      if (time) time.value = parts.time ?? '';
    },
    focus: () => day.focus(),
  };
}

export const INVALID_DATE_MESSAGE = 'تاریخ واردشده کامل یا معتبر نیست.';

/** Start of the local day of an ISO date as a UTC instant (for "from" filters). */
export function startOfLocalDay(isoDate) {
  return localPartsToInstant({ date: isoDate, time: '00:00' });
}

/** Last second of the local day of an ISO date as a UTC instant (for inclusive "to" filters). */
export function endOfLocalDay(isoDate) {
  const start = localPartsToInstant({ date: isoDate, time: '00:00' });
  if (start === null) return null;
  const end = new Date(new Date(start).getTime() + 86_400_000 - 1000);
  return end.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** The local calendar date ("YYYY-MM-DD") of an instant, for pre-filling date filters from the URL. */
export function localDateOf(instant) {
  return instantToLocalParts(instant).date;
}

/**
 * Builds a `<form>` from named fields and handles submission:
 * the submit button shows progress, API validation errors land next to their fields and
 * everything else is shown in an alert above the buttons.
 *
 * `onSubmit(values, form)` may throw; `validate(values)` may return `{ field: message }`.
 */
export function buildForm({
  fields,
  layout = [],
  submitLabel = 'ذخیره',
  submitIcon = null,
  cancelLabel = null,
  onCancel = null,
  onSubmit,
  validate = null,
  errorAliases = {},
  actionsClass = 'form-actions',
  submitClass = 'btn',
  extraActions = [],
}) {
  const formError = h('div', { hidden: true });
  const submit = h('button', { type: 'submit', class: submitClass }, submitIcon && icon(submitIcon), submitLabel);
  const actions = h(
    'div',
    { class: actionsClass },
    extraActions,
    cancelLabel && h('button', { type: 'button', class: 'btn btn-secondary', onClick: () => onCancel?.() }, cancelLabel),
    submit,
  );
  const body = layout.length > 0 ? layout : Object.values(fields).map((field) => field.element);
  const element = h('form', { class: 'form', novalidate: true }, body, formError, actions);

  const controller = {
    element,
    fields,
    submitButton: submit,
    actions,
    values: () => Object.fromEntries(Object.entries(fields).map(([name, field]) => [name, field.getValue()])),
    clearErrors() {
      for (const field of Object.values(fields)) field.setError(null);
      formError.hidden = true;
      formError.replaceChildren();
    },
    setFormError(message) {
      formError.replaceChildren(alertBox('danger', message));
      formError.hidden = false;
    },
    /** Shows `{ name: message }` next to the fields; unknown names are listed in the form alert. Returns true if any. */
    setErrors(errors) {
      const unmatched = [];
      let first = null;
      for (const [name, message] of Object.entries(errors)) {
        const text = Array.isArray(message) ? message.join(' ') : String(message);
        const field = fields[errorAliases[name] ?? name];
        if (field) {
          field.setError(text);
          first ??= field;
        } else {
          unmatched.push(text);
        }
      }
      if (unmatched.length > 0) controller.setFormError(unmatched.join(' '));
      first?.focus?.();
      return first !== null || unmatched.length > 0;
    },
    /** Maps a thrown error onto the form. */
    showError(error) {
      if (error instanceof ApiError && Object.keys(error.fields).length > 0) {
        const shown = controller.setErrors(error.fields);
        if (!shown || !error.isValidation) controller.setFormError(errorMessage(error));
      } else {
        controller.setFormError(errorMessage(error));
      }
    },
  };

  element.addEventListener('submit', (event) => {
    event.preventDefault();
    controller.clearErrors();
    const values = controller.values();
    const problems = validate?.(values) ?? {};
    if (Object.keys(problems).length > 0) {
      controller.setErrors(problems);
      return;
    }
    withBusyButton(submit, async () => {
      try {
        await onSubmit(values, controller);
      } catch (error) {
        controller.showError(error);
      }
    });
  });

  return controller;
}

export function requiredProblems(values, labels) {
  const problems = {};
  for (const [name, message] of Object.entries(labels)) {
    const value = values[name];
    if (value === null || value === undefined || (typeof value === 'string' && value.trim() === '')) problems[name] = message;
  }
  return problems;
}

/**
 * Wraps a filter form in a collapsible panel. It starts open on wide screens and whenever a
 * filter is active, and collapsed on phones, where the form would push the results off-screen.
 */
export function filterPanel(form, { active = false } = {}) {
  form.element.className = 'toolbar';
  const wide = window.matchMedia('(min-width: 720px)').matches;
  return h(
    'details',
    { class: 'filters', open: wide || active },
    h('summary', {}, icon('search', { size: 16 }), active ? 'فیلترها (فعال)' : 'فیلترها'),
    form.element,
  );
}
