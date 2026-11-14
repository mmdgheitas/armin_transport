/**
 * The built client as served by the backend: security headers, caching, and what an
 * anonymous visitor gets before signing in.
 */

import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { after, test } from 'node:test';

import { SECURITY_HEADERS, createDevServer } from '../../scripts/dev-server.mjs';
import { WEB_ROOT } from './support/backend.mjs';
import { PHONE, signIn, useApp } from './support/ui.mjs';

// `npm run dev`: the unbuilt sources in front of the same backend.
let devServer = null;
let devOrigin = null;

const app = useApp({
  async prepare({ baseUrl }) {
    devServer = createDevServer({ sourceDir: path.join(WEB_ROOT, 'src'), backendUrl: baseUrl });
    devServer.listen(0, '127.0.0.1');
    await once(devServer, 'listening');
    devOrigin = `http://127.0.0.1:${devServer.address().port}`;
  },
});

after(() => {
  devServer?.closeAllConnections();
  devServer?.close();
});

test('pages are served with a strict Content-Security-Policy and are revalidated on every visit', async () => {
  const response = await fetch(`${app.baseUrl}/`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^text\/html/);

  const directives = Object.fromEntries(
    response.headers
      .get('content-security-policy')
      .split(';')
      .map((part) => part.trim().split(/\s+/))
      .map(([name, ...values]) => [name, values.join(' ')]),
  );
  assert.equal(directives['default-src'], "'self'");
  assert.equal(directives['script-src'], "'self'", 'no inline or evaluated scripts');
  assert.equal(directives['style-src'], "'self'", 'no inline styles');
  assert.equal(directives['connect-src'], "'self'");
  assert.equal(directives['object-src'], "'none'");
  assert.equal(directives['base-uri'], "'self'");
  assert.equal(directives['frame-ancestors'], "'none'");

  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(response.headers.get('x-frame-options'), 'DENY');
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(response.headers.get('cache-control'), 'no-cache');
  assert.ok(response.headers.get('etag'), 'an ETag makes revalidation cheap');

  const revalidated = await fetch(`${app.baseUrl}/`, { headers: { 'If-None-Match': response.headers.get('etag') } });
  assert.equal(revalidated.status, 304);
});

test('every module is requested with the build stamp, so a deployment never mixes versions', async () => {
  const build = JSON.parse(await readFile(path.join(WEB_ROOT, 'dist', 'build.json'), 'utf8'));
  const html = await (await fetch(`${app.baseUrl}/`)).text();
  assert.ok(html.includes(`js/main.js?v=${build.build_id}`));
  assert.ok(html.includes(`assets/css/app.css?v=${build.build_id}`));
  assert.ok(!html.includes('__BUILD_ID__'));
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)/, 'no inline scripts');
  assert.doesNotMatch(html, /<style|\sstyle=/, 'no inline styles');

  const main = await (await fetch(`${app.baseUrl}/js/main.js?v=${build.build_id}`)).text();
  assert.ok(main.includes(`./app.js?v=${build.build_id}`));
});

test('API responses are never cached and files outside the client are not served', async () => {
  const health = await fetch(`${app.apiUrl}/health`);
  assert.equal(health.status, 200);
  assert.equal(health.headers.get('cache-control'), 'no-store');
  assert.equal(health.headers.get('content-security-policy'), "default-src 'none'; frame-ancestors 'none'");

  for (const route of ['/.env', '/wsgi.py', '/js/', '/js/%2e%2e/%2e%2e/%2e%2e/backend/wsgi.py', '/..%2f..%2fbackend%2fwsgi.py', '/assets/../../backend/wsgi.py']) {
    const response = await fetch(`${app.baseUrl}${route}`);
    assert.equal(response.status, 404, `${route} must not be served`);
    assert.ok(!(await response.text()).includes('create_app'), `${route} leaked a source file`);
  }
});

app.scenario('an anonymous visitor lands on the Persian, right-to-left tracking page with the bundled font', async (ui) => {
  await ui.open();
  await ui.waitForHash('#/track');
  await ui.waitForText('رهگیری محموله');

  const document = await ui.page.evaluate(async () => {
    await window.document.fonts.ready;
    return {
      lang: window.document.documentElement.lang,
      dir: window.document.documentElement.dir,
      title: window.document.title,
      bodyFont: window.getComputedStyle(window.document.body).fontFamily,
      loadedFonts: [...window.document.fonts].filter((font) => font.status === 'loaded').map((font) => font.family.replaceAll('"', '')),
    };
  });
  assert.equal(document.lang, 'fa');
  assert.equal(document.dir, 'rtl');
  assert.equal(document.title, 'رهگیری محموله | حمل‌ونقل');
  assert.match(document.bodyFont, /^"?Vazirmatn/);
  assert.ok(document.loadedFonts.includes('Vazirmatn'), `the Vazirmatn web font was not loaded (loaded: ${document.loadedFonts})`);

  const foreign = ui.requests('').filter((request) => !request.url.startsWith(app.baseUrl) && !/^(data|blob):/.test(request.url));
  assert.deepEqual(foreign, [], 'the client must not load anything from another origin');

  await ui.assertLayout('tracking page');
  assert.deepEqual(await ui.names('link'), ['حمل‌ونقل', 'ورود کارکنان']);
});

app.scenario('protected pages send a visitor to the login form and unknown addresses show a not-found page', async (ui) => {
  await ui.open('#/shipments');
  await ui.waitForHash('#/login?next=%23%2Fshipments');
  await ui.waitForText('ورود کارکنان');
  assert.deepEqual(ui.requests('/api/'), [], 'no API request may be sent before signing in');
  await ui.assertLayout('login page');

  await ui.go('#/no-such-page');
  await ui.waitForText('صفحهٔ موردنظر یافت نشد.');
  await ui.click('بازگشت به صفحهٔ اصلی', { role: 'link' });
  await ui.waitForHash('#/track');
});

app.scenario(
  'the public pages fit a phone screen',
  async (ui) => {
    await ui.open('#/track');
    await ui.waitForText('رهگیری محموله');
    await ui.assertLayout('tracking page on a phone');
    await ui.screenshot('phone-track');

    await ui.click('ورود کارکنان', { role: 'link' });
    await ui.waitForHash('#/login');
    await ui.assertLayout('login page on a phone');
    await ui.screenshot('phone-login');
  },
  { viewport: PHONE },
);

test('the development server sends the same Content-Security-Policy as the backend', async () => {
  const served = (await fetch(`${app.baseUrl}/`)).headers.get('content-security-policy');
  // Who may embed the pages is a deployment setting; everything else has to be identical.
  const withoutEmbedding = (policy) => policy.replace(/; frame-ancestors [^;]+$/, '');
  assert.match(served, /; frame-ancestors [^;]+$/);
  assert.equal(withoutEmbedding(SECURITY_HEADERS['Content-Security-Policy']), withoutEmbedding(served));
  assert.equal((await fetch(`${devOrigin}/`)).headers.get('content-security-policy'), SECURITY_HEADERS['Content-Security-Policy']);
});

app.scenario(
  'the unbuilt sources work behind the development server',
  async (ui) => {
    await ui.open('#/shipments');
    await signIn(ui, 'armin.operator', app.password, { landing: '#/shipments' });
    await ui.waitForRow('پالت لوازم خانگی - مقصد شیراز', 'فهرست محموله‌ها');
    // Modules come from src/ as they are, and the API is reached through the proxy on the same origin.
    const urls = (part) => ui.requests(part).map((request) => request.url);
    assert.deepEqual(urls('/js/main.js'), [`${devOrigin}/js/main.js?v=dev`]);
    assert.deepEqual(urls('/js/app.js'), [`${devOrigin}/js/app.js`]);
    assert.ok(urls('/api/v1/shipments').length > 0);
    assert.ok(urls('/api/v1/').every((url) => url.startsWith(`${devOrigin}/api/v1/`)));
    await ui.click('خروج');
    await ui.waitForHash('#/login');
  },
  { origin: () => devOrigin },
);
