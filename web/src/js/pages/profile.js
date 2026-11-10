import { h, ltr } from '../core/dom.js';
import { formatDateTime, toPersianDigits } from '../core/format.js';
import { toast } from '../ui/feedback.js';
import { buildForm, passwordField, requiredProblems } from '../ui/forms.js';
import { pageHeader } from '../ui/layout.js';
import { keyValueList, roleLabel } from '../ui/table.js';

export function profilePage(ctx) {
  const { api, session } = ctx;
  const user = session.user;
  const minPassword = session.appSettings.password?.min_length ?? 10;

  const form = buildForm({
    fields: {
      current_password: passwordField({ label: 'رمز عبور فعلی', autocomplete: 'current-password' }),
      new_password: passwordField({
        label: 'رمز عبور جدید',
        autocomplete: 'new-password',
        hint: `دست‌کم ${toPersianDigits(minPassword)} نویسه؛ نباید شامل نام کاربری باشد.`,
      }),
      confirm_password: passwordField({ label: 'تکرار رمز عبور جدید', autocomplete: 'new-password' }),
    },
    submitLabel: 'تغییر رمز عبور',
    submitIcon: 'key',
    validate(values) {
      const problems = requiredProblems(values, {
        current_password: 'رمز عبور فعلی را وارد کنید.',
        new_password: 'رمز عبور جدید را وارد کنید.',
        confirm_password: 'رمز عبور جدید را دوباره وارد کنید.',
      });
      if (!problems.confirm_password && values.new_password !== values.confirm_password) problems.confirm_password = 'تکرار رمز عبور با رمز جدید یکسان نیست.';
      return problems;
    },
    async onSubmit(values, controller) {
      const { message } = await api.changePassword(values.current_password, values.new_password);
      toast.success(message);
      for (const field of Object.values(controller.fields)) field.setValue('');
    },
  });

  return {
    title: 'حساب کاربری',
    element: h(
      'div',
      { class: 'stack' },
      pageHeader({ title: 'حساب کاربری' }),
      h(
        'section',
        { class: 'card' },
        h('div', { class: 'card-header' }, h('h2', {}, 'مشخصات')),
        h(
          'div',
          { class: 'card-body' },
          keyValueList([
            ['نام', user?.full_name ?? '—'],
            ['نام کاربری', ltr(user?.username ?? '', 'code')],
            ['نقش', roleLabel(user?.role)],
            ['شرکت', user?.company?.name ?? null],
            ['آخرین ورود', user?.last_login_at ? formatDateTime(user.last_login_at, { style: 'long' }) : null],
          ]),
        ),
      ),
      h(
        'section',
        { class: 'card' },
        h('div', { class: 'card-header' }, h('h2', {}, 'تغییر رمز عبور')),
        h('div', { class: 'card-body stack' }, h('p', { class: 'muted small' }, 'پس از تغییر رمز، نشست شما در دستگاه‌های دیگر بسته می‌شود.'), form.element),
      ),
    ),
  };
}
