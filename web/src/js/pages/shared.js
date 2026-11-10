/** Helpers shared by the pages: async sections, bulk loading and dynamic product-field controls. */

import { isAbortError } from '../core/api.js';
import { h, mount } from '../core/dom.js';
import { apiValueToInput, describeRules } from '../core/fields.js';
import { errorBlock, loadingBlock } from '../ui/feedback.js';
import { jalaliDateField, multiCheckField, selectField, textField } from '../ui/forms.js';

const BULK_PAGE_SIZE = 100;
const BULK_PAGE_LIMIT = 50;

/**
 * A region that loads data and renders it, with loading and error states.
 * `load(signal)` fetches; `render(data, reload)` returns the content. Returns `{ element, reload }`.
 */
export function asyncBlock(ctx, load, render, { loadingText } = {}) {
  const element = h('div');
  const reload = async () => {
    mount(element, loadingBlock(loadingText));
    try {
      const data = await load(ctx.signal);
      if (ctx.signal.aborted) return;
      mount(element, render(data, reload));
    } catch (error) {
      if (isAbortError(error) || ctx.signal.aborted) return;
      mount(element, errorBlock(error, reload));
    }
  };
  reload();
  return { element, reload };
}

/**
 * Loads every page of a paginated collection (bounded; for pick lists such as companies).
 * The page size follows the limit announced by the server so the request is never rejected.
 */
export async function loadAll(ctx, path, query = {}) {
  const perPage = Math.min(BULK_PAGE_SIZE, ctx.session.appSettings.pagination?.max_page_size ?? 20);
  const items = [];
  for (let page = 1; page <= BULK_PAGE_LIMIT; page += 1) {
    const { data } = await ctx.api.get(path, { query: { ...query, page, per_page: perPage }, signal: ctx.signal });
    items.push(...data.items);
    if (!data.pagination.has_next) break;
  }
  return items;
}

export function companyOptions(companies) {
  return companies.map((company) => ({
    value: company.id,
    label: company.is_active ? `${company.name} (${company.company_code})` : `${company.name} (${company.company_code}) - غیرفعال`,
  }));
}

/** Parses the `page` query parameter into a positive integer. */
export function pageNumber(query) {
  const page = Number.parseInt(query.page ?? '1', 10);
  return Number.isInteger(page) && page > 0 ? page : 1;
}

/**
 * Loads the page of a collection that the `page` parameter of the address names; `filters` are the other
 * query parameters. An address beyond the last page (an old bookmark, or a list that became shorter) is
 * corrected to the last page instead of showing an empty list.
 */
export async function loadListPage(ctx, path, filters, signal) {
  const page = pageNumber(ctx.query);
  const { data } = await ctx.api.get(path, { signal, query: { ...filters, page } });
  const { total, total_pages: totalPages } = data.pagination;
  if (data.items.length === 0 && total > 0 && page > totalPages) {
    ctx.setQuery({ page: totalPages > 1 ? totalPages : null }, { replace: true });
    // The corrected address renders the page again; this load is abandoned like any other superseded one.
    throw new DOMException('The address pointed beyond the last page.', 'AbortError');
  }
  return data;
}

/**
 * Builds the form control for a dynamic product field, pre-filled with `value`
 * (the raw API value). The control's `getValue()` yields the state understood by
 * `inputToApiValue` in core/fields.js.
 */
export function productFieldControl(field, value = null) {
  const common = { label: field.label, required: field.is_required };
  const initial = apiValueToInput(field, value);
  const options = (field.options ?? []).map((option) => ({ value: option.value, label: option.label }));
  switch (field.data_type) {
    case 'NUMBER':
      return textField({ ...common, value: initial, dir: 'ltr', inputmode: 'numeric', hint: describeRules(field), maxlength: 20 });
    case 'DECIMAL':
      return textField({ ...common, value: initial, dir: 'ltr', inputmode: 'decimal', hint: describeRules(field), maxlength: 40 });
    case 'DATE': {
      const control = jalaliDateField({ ...common, value: initial, hint: describeRules(field) });
      return wrapDate(control);
    }
    case 'DATETIME': {
      const control = jalaliDateField({ ...common, value: initial, withTime: true, hint: describeRules(field) });
      return wrapDate(control);
    }
    case 'BOOLEAN':
      return selectField({
        ...common,
        value: initial,
        placeholder: 'انتخاب نشده',
        options: [
          { value: 'true', label: 'بله' },
          { value: 'false', label: 'خیر' },
        ],
      });
    case 'SELECT':
      return selectField({ ...common, value: initial, placeholder: 'انتخاب نشده', options });
    case 'MULTI_SELECT':
      return multiCheckField({ ...common, value: initial, options, hint: describeRules(field) });
    default:
      return textField({ ...common, value: initial, hint: describeRules(field), maxlength: 2000, multiline: (field.validation_rules?.max_length ?? 0) > 300 });
  }
}

/** Marks an impossible date so the form can refuse it before anything is sent. */
function wrapDate(control) {
  return { ...control, isDate: true };
}

/** Reads all product-field controls. Returns `{ inputs, errors }`; impossible dates are reported as errors. */
export function readProductControls(controls) {
  const inputs = {};
  const errors = {};
  for (const [key, control] of Object.entries(controls)) {
    const value = control.getValue();
    if (control.isDate && value === null) errors[key] = 'تاریخ واردشده کامل یا معتبر نیست.';
    else inputs[key] = value;
  }
  return { inputs, errors };
}

export function showProductErrors(controls, errors) {
  let first = null;
  for (const [key, control] of Object.entries(controls)) {
    control.setError(errors[key] ?? null);
    if (errors[key]) first ??= control;
  }
  first?.focus?.();
  return first !== null;
}
