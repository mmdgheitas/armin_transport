import { h } from '../core/dom.js';
import { safeNextHash } from '../core/router.js';
import { buildForm, passwordField, requiredProblems, textField } from '../ui/forms.js';
import { toast } from '../ui/feedback.js';

export function loginPage(ctx) {
  const form = buildForm({
    fields: {
      username: textField({ label: 'نام کاربری', dir: 'ltr', autocomplete: 'username', required: true, maxlength: 100 }),
      password: passwordField({ label: 'رمز عبور' }),
    },
    submitLabel: 'ورود',
    submitIcon: 'lock',
    submitClass: 'btn btn-lg btn-block',
    actionsClass: 'stack-sm',
    validate: (values) => requiredProblems(values, { username: 'نام کاربری را وارد کنید.', password: 'رمز عبور را وارد کنید.' }),
    async onSubmit(values) {
      const { message } = await ctx.api.login(values.username.trim(), values.password);
      toast.success(message);
      ctx.navigate(safeNextHash(ctx.query.next), { replace: true });
    },
  });
  setTimeout(() => form.fields.username.focus(), 0);

  return {
    title: 'ورود به پنل کاربری',
    element: h(
      'div',
      { class: 'card card-elevated' },
      h(
        'div',
        { class: 'card-body stack' },
        h('div', {}, h('h1', {}, 'ورود به پنل کاربری'), h('p', { class: 'muted' }, 'برای ورود به پنل مدیریت محموله‌ها، نام کاربری و رمز عبور خود را وارد کنید.')),
        form.element,
      ),
    ),
  };
}
