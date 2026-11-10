import { h, icon } from '../core/dom.js';
import { collectFieldValues, fieldErrorsFromApi } from '../core/fields.js';
import { ApiError } from '../core/api.js';
import { normalizeTrackingCode, trackingCodeProblem } from '../core/tracking.js';
import { alertBox, errorMessage, toast, withBusyButton } from '../ui/feedback.js';
import { selectField, textField } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { asyncBlock, companyOptions, loadAll, productFieldControl, readProductControls, showProductErrors } from './shared.js';

export function shipmentNewPage(ctx) {
  const { api, session } = ctx;
  const isGlobal = session.isGlobalScope;
  const canUseManualCode = session.can('tracking_code:manual');
  const codeRules = session.appSettings.tracking_code;

  const block = asyncBlock(
    ctx,
    async () => {
      const [fields, companies] = await Promise.all([
        loadAll(ctx, '/product-fields'),
        isGlobal ? loadAll(ctx, '/companies', { is_active: true }) : Promise.resolve([]),
      ]);
      return { fields, companies };
    },
    ({ fields, companies }) => {
      if (isGlobal && companies.length === 0) {
        return alertBox('warning', 'برای ثبت محموله ابتدا باید دست‌کم یک شرکت فعال تعریف شود. ', h('a', { href: '#/companies' }, 'مدیریت شرکت‌ها'));
      }

      const company = isGlobal
        ? selectField({ label: 'شرکت', required: true, placeholder: 'انتخاب کنید', options: companyOptions(companies), value: companies.length === 1 ? companies[0].id : '' })
        : null;
      const description = textField({ label: 'توضیحات', multiline: true, maxlength: 5000, hint: 'مثلاً نوع بار و مقصد. بسته به تنظیمات سامانه ممکن است برای مشتری نمایش داده شود.' });

      const manualCode = textField({
        label: 'کد رهگیری دستی',
        dir: 'ltr',
        inputClass: 'code',
        maxlength: 200,
        required: true,
        hint: 'حروف انگلیسی، رقم و خط تیره. کد پس از ثبت یکتا می‌ماند و قابل استفادهٔ دوباره نیست.',
      });
      manualCode.element.hidden = true;
      let mode = 'auto';
      const modeControl = canUseManualCode
        ? h(
            'div',
            { class: 'field' },
            h('span', { class: 'field-label' }, 'کد رهگیری'),
            h(
              'div',
              { class: 'segmented', role: 'radiogroup', 'aria-label': 'نوع کد رهگیری' },
              ...[
                ['auto', 'تولید خودکار'],
                ['manual', 'ورود دستی'],
              ].map(([value, label]) =>
                h(
                  'label',
                  {},
                  h('input', {
                    type: 'radio',
                    name: 'code-mode',
                    value,
                    checked: value === 'auto',
                    onChange: () => {
                      mode = value;
                      manualCode.element.hidden = mode !== 'manual';
                      if (mode === 'manual') manualCode.focus();
                    },
                  }),
                  h('span', {}, label),
                ),
              ),
            ),
          )
        : alertBox('info', 'کد رهگیری پس از ثبت به‌صورت خودکار، یکتا و غیرقابل‌حدس تولید می‌شود.');

      const controls = Object.fromEntries(fields.map((field) => [field.field_key, productFieldControl(field)]));
      const formError = h('div', { hidden: true });
      const submit = h('button', { type: 'submit', class: 'btn btn-lg' }, icon('check'), 'ثبت محموله');

      const form = h(
        'form',
        { class: 'stack', novalidate: true },
        h(
          'section',
          { class: 'card' },
          h('div', { class: 'card-header' }, h('h2', {}, 'اطلاعات محموله')),
          h('div', { class: 'card-body form' }, company && company.element, modeControl, manualCode.element, description.element),
        ),
        fields.length > 0 &&
          h(
            'section',
            { class: 'card' },
            h('div', { class: 'card-header' }, h('h2', {}, 'مشخصات کالا')),
            h('div', { class: 'card-body form-grid' }, fields.map((field) => controls[field.field_key].element)),
          ),
        formError,
        h('div', { class: 'form-actions' }, h('a', { class: 'btn btn-secondary btn-lg', href: '#/shipments' }, 'انصراف'), submit),
      );

      form.addEventListener('submit', (event) => {
        event.preventDefault();
        formError.hidden = true;
        company?.setError(null);
        manualCode.setError(null);
        description.setError(null);

        const payload = {};
        let firstInvalid = null;
        if (company) {
          if (!company.getValue()) {
            company.setError('شرکت را انتخاب کنید.');
            firstInvalid ??= company;
          }
          payload.company_id = company.getValue();
        }
        if (mode === 'manual') {
          const code = normalizeTrackingCode(manualCode.getValue());
          manualCode.setValue(code);
          const problem = trackingCodeProblem(code, codeRules);
          if (problem) {
            manualCode.setError(problem);
            firstInvalid ??= manualCode;
          }
          payload.tracking_code = code;
        }
        if (description.getValue().trim() !== '') payload.description = description.getValue().trim();

        const { inputs, errors: dateErrors } = readProductControls(controls);
        const { values, errors: valueErrors } = collectFieldValues(
          fields.filter((field) => !(field.field_key in dateErrors)),
          inputs,
        );
        const productErrors = { ...valueErrors, ...dateErrors };
        const hasProductErrors = showProductErrors(controls, productErrors);
        if (firstInvalid) firstInvalid.focus();
        if (firstInvalid || hasProductErrors) return;
        if (fields.length > 0) payload.product_values = values;

        withBusyButton(submit, async () => {
          try {
            const { data, message } = await api.post('/shipments', { json: payload });
            toast.success(message);
            ctx.navigate(`#/shipments/${data.id}`);
          } catch (error) {
            const apiFields = error instanceof ApiError ? error.fields : {};
            const mapped = showProductErrors(controls, fieldErrorsFromApi(apiFields));
            if (apiFields.tracking_code) manualCode.setError(apiFields.tracking_code.join(' '));
            if (apiFields.company_id) company?.setError(apiFields.company_id.join(' '));
            if (apiFields.description) description.setError(apiFields.description.join(' '));
            if (error instanceof ApiError && error.code === 'tracking_code_taken') manualCode.setError(error.message);
            if (!mapped || !(error instanceof ApiError) || !error.isValidation) {
              formError.replaceChildren(alertBox('danger', errorMessage(error)));
              formError.hidden = false;
            }
          }
        });
      });

      return form;
    },
  );

  return {
    title: 'ثبت محمولهٔ جدید',
    element: h(
      'div',
      {},
      pageHeader({ title: 'ثبت محمولهٔ جدید', description: 'پس از ثبت، کد رهگیری را در اختیار مشتری قرار دهید و سندها را بارگذاری کنید.' }),
      block.element,
    ),
  };
}
