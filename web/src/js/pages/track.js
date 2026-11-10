/**
 * Customer portal: look up a shipment by tracking code and read its public details.
 *
 * The lookup returns a short-lived access token that is kept in sessionStorage
 * (this tab only) and is never placed in the page address.
 */

import { ApiError, isAbortError } from '../core/api.js';
import { h, icon, ltr, mount, saveBlob } from '../core/dom.js';
import { formatDateTime, formatFieldValue, formatFileSize, formatNumber, formatTime } from '../core/format.js';
import { normalizeTrackingCode } from '../core/tracking.js';
import { alertBox, emptyBlock, errorBlock, errorMessage, loadingBlock, toast, withBusyButton } from '../ui/feedback.js';
import { keyValueList, paginationBar, shipmentStatusBadge } from '../ui/table.js';

const GRANT_KEY = 'armin-transport.customer-access.v1';
const SESSION_ENDED = 'نشست مشاهدهٔ محموله به پایان رسیده است. برای ادامه، کد رهگیری را دوباره وارد کنید.';

function readGrant() {
  try {
    const grant = JSON.parse(window.sessionStorage.getItem(GRANT_KEY) ?? 'null');
    if (grant && typeof grant.token === 'string' && new Date(grant.expiresAt).getTime() > Date.now()) return grant;
  } catch {
    // Corrupted or unavailable storage is treated as "no session".
  }
  return null;
}

function storeGrant(grant) {
  try {
    if (grant) window.sessionStorage.setItem(GRANT_KEY, JSON.stringify(grant));
    else window.sessionStorage.removeItem(GRANT_KEY);
  } catch {
    // Without storage the session simply does not survive a reload.
  }
}

const isSessionOver = (error) => error instanceof ApiError && error.status === 401;

export function trackPage(ctx) {
  const host = h('div');
  const accessPath = (grant, suffix) => `/customer/access/${encodeURIComponent(grant.token)}${suffix}`;

  function showLookup(notice = null) {
    const input = h('input', {
      class: 'input code',
      type: 'text',
      dir: 'ltr',
      name: 'tracking_code',
      'aria-label': 'کد رهگیری',
      placeholder: 'ABCD-1234-EFGH-5678',
      autocomplete: 'off',
      autocapitalize: 'characters',
      spellcheck: 'false',
      maxlength: 200,
      required: true,
    });
    const submit = h('button', { type: 'submit', class: 'btn btn-lg' }, icon('search'), 'رهگیری');
    const message = h('div', { class: 'stack-sm' }, notice && alertBox('info', notice));
    const form = h('form', { class: 'track-form', novalidate: true }, input, submit);

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const code = normalizeTrackingCode(input.value);
      input.value = code;
      if (code === '') {
        mount(message, alertBox('danger', 'کد رهگیری را وارد کنید.'));
        input.focus();
        return;
      }
      withBusyButton(submit, async () => {
        try {
          const { data } = await ctx.api.post('/customer/lookup', { auth: false, json: { tracking_code: code }, signal: ctx.signal });
          const grant = { token: data.access_token, expiresAt: data.expires_at };
          storeGrant(grant);
          showShipment(grant);
        } catch (error) {
          if (isAbortError(error)) return;
          mount(message, alertBox('danger', errorMessage(error)));
          input.focus();
          input.select();
        }
      });
    });

    mount(
      host,
      h(
        'div',
        { class: 'stack' },
        h('div', { class: 'hero' }, h('h1', {}, 'رهگیری محموله'), h('p', {}, 'کد رهگیری‌ای را که هنگام تحویل بار دریافت کرده‌اید وارد کنید تا وضعیت و سندهای محموله را ببینید.')),
        form,
        h('div', { class: 'track-form' }, h('div', { class: 'grow' }, message)),
      ),
    );
    setTimeout(() => input.focus(), 0);
  }

  function endLocally(notice) {
    storeGrant(null);
    showLookup(notice);
  }

  function documentsCard(grant) {
    const body = h('div');
    const load = async (page) => {
      mount(body, loadingBlock());
      try {
        const { data } = await ctx.api.get(accessPath(grant, '/documents'), { auth: false, query: { page, per_page: 20 }, signal: ctx.signal });
        if (ctx.signal.aborted) return;
        if (data.items.length === 0) {
          mount(body, emptyBlock({ iconName: 'file', title: 'سندی برای این محموله در دسترس نیست.' }));
          return;
        }
        mount(
          body,
          h(
            'div',
            { class: 'card-body' },
            data.items.map((item) => {
              const button = h('button', { type: 'button', class: 'btn btn-secondary btn-sm' }, icon('download', { size: 16 }), 'دریافت');
              button.addEventListener('click', () =>
                withBusyButton(button, async () => {
                  try {
                    const file = await ctx.api.download(accessPath(grant, `/documents/${item.id}/download`), { auth: false });
                    saveBlob(file.blob, file.filename === 'download' ? item.name : file.filename);
                  } catch (error) {
                    if (isSessionOver(error)) endLocally(SESSION_ENDED);
                    else toast.error(errorMessage(error));
                  }
                }),
              );
              return h(
                'div',
                { class: 'doc-item' },
                h('div', { class: 'doc-icon' }, icon('file', { size: 20 })),
                h(
                  'div',
                  { class: 'grow' },
                  h('div', { class: 'file-name' }, ltr(item.name)),
                  h('div', { class: 'small muted' }, `${formatFileSize(item.file_size)} · ${formatDateTime(item.uploaded_at)}`),
                ),
                button,
              );
            }),
          ),
          data.pagination.total_pages > 1 && paginationBar(data.pagination, load),
        );
      } catch (error) {
        if (isAbortError(error) || ctx.signal.aborted) return;
        if (isSessionOver(error)) endLocally(SESSION_ENDED);
        else mount(body, errorBlock(error, () => load(page)));
      }
    };
    load(1);
    return h('section', { class: 'card' }, h('div', { class: 'card-header' }, h('h2', {}, 'سندهای محموله')), body);
  }

  async function showShipment(grant) {
    mount(host, loadingBlock('در حال دریافت اطلاعات محموله…'));
    let shipment;
    try {
      shipment = (await ctx.api.get(accessPath(grant, '/shipment'), { auth: false, signal: ctx.signal })).data;
    } catch (error) {
      if (isAbortError(error) || ctx.signal.aborted) return;
      if (isSessionOver(error)) endLocally(SESSION_ENDED);
      else mount(host, errorBlock(error, () => showShipment(grant)));
      return;
    }
    if (ctx.signal.aborted) return;

    const finish = h('button', { type: 'button', class: 'btn btn-secondary' }, icon('logout', { size: 16 }), 'پایان و جست‌وجوی کد دیگر');
    finish.addEventListener('click', () =>
      withBusyButton(finish, async () => {
        try {
          await ctx.api.post(accessPath(grant, '/revoke'), { auth: false });
        } catch {
          // The session expires on its own shortly; ending it locally is what matters to the visitor.
        }
        endLocally(null);
      }),
    );

    const details = shipment.product_details ?? [];
    mount(
      host,
      h(
        'div',
        { class: 'portal-grid' },
        h(
          'section',
          { class: 'card full' },
          h(
            'div',
            { class: 'card-body stack' },
            h(
              'div',
              { class: 'row-between' },
              h('div', { class: 'row' }, h('h1', {}, 'محموله'), h('span', { class: 'tracking-code' }, ltr(shipment.tracking_code)), shipmentStatusBadge(shipment.status)),
              finish,
            ),
            keyValueList([
              ['شرکت حمل‌ونقل', shipment.company_name],
              ['تاریخ ثبت', formatDateTime(shipment.registered_at, { style: 'long' })],
              ['تعداد سندها', formatNumber(shipment.document_count)],
              ['توضیحات', shipment.description],
            ]),
          ),
          h(
            'div',
            { class: 'card-footer small muted' },
            icon('clock', { size: 14 }),
            ` برای حفظ امنیت، این صفحه تا ساعت ${formatTime(shipment.session_expires_at)} در دسترس است و پس از آن باید کد رهگیری را دوباره وارد کنید.`,
          ),
        ),
        h(
          'section',
          { class: 'card' },
          h('div', { class: 'card-header' }, h('h2', {}, 'مشخصات کالا')),
          details.length > 0
            ? h('div', { class: 'card-body' }, keyValueList(details.map((detail) => [detail.label, formatFieldValue(detail.data_type, detail.value)])))
            : emptyBlock({ iconName: 'package', title: 'مشخصاتی برای نمایش ثبت نشده است.' }),
        ),
        documentsCard(grant),
      ),
    );
  }

  const grant = readGrant();
  if (grant) showShipment(grant);
  else showLookup();

  return {
    title: 'رهگیری محموله',
    headerLink: ctx.session.isAuthenticated()
      ? { href: '#/dashboard', label: 'بازگشت به پنل', iconName: 'grid' }
      : { href: '#/login', label: 'ورود کارکنان', iconName: 'lock' },
    element: host,
  };
}
