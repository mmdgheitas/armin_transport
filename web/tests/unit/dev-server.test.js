import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { createDevServer } from '../../scripts/dev-server.mjs';

const SOURCES = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'src');

async function listen(server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
  server.closeAllConnections();
  server.close();
  await once(server, 'close');
}

/** Sends the path exactly as written (fetch would tidy up "/../" before sending). */
function rawGet(origin, rawPath) {
  return new Promise((resolve, reject) => {
    const { hostname, port } = new URL(origin);
    const request = http.request({ hostname, port, path: rawPath, method: 'GET' }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    request.on('error', reject);
    request.end();
  });
}

// A stand-in for the Flask API: it reports what it received.
const seen = [];
const backend = http.createServer((request, response) => {
  const chunks = [];
  request.on('data', (chunk) => chunks.push(chunk));
  request.on('end', () => {
    const raw = Buffer.concat(chunks);
    const received = { method: request.method, url: request.url, headers: request.headers, body: raw.toString('utf8') };
    seen.push({ ...received, raw });
    if (request.url.startsWith('/api/v1/documents/')) {
      response.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Disposition': 'attachment; filename="bill.pdf"' });
      response.end(Buffer.from([0x25, 0x50, 0x44, 0x46, 0x00, 0xff, 0xfe]));
      return;
    }
    const status = request.method === 'POST' ? 201 : request.url.includes('missing') ? 404 : 200;
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'X-Request-ID': 'req-from-backend', 'Cache-Control': 'no-store' });
    response.end(JSON.stringify({ success: status < 400, message: 'پاسخ سرور', data: received, errors: null }));
  });
});

let backendUrl;
let server;
let origin;

before(async () => {
  backendUrl = await listen(backend);
  server = createDevServer({ sourceDir: SOURCES, backendUrl });
  origin = await listen(server);
});

after(async () => {
  await close(server);
  await close(backend);
});

test('the page is served from the sources under the policy the backend uses for the built client', async () => {
  for (const address of ['/', '/index.html']) {
    const response = await fetch(`${origin}${address}`);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8');
    const html = await response.text();
    assert.ok(html.includes('<html lang="fa" dir="rtl">'));
    assert.ok(html.includes('src="js/main.js?v=dev"'));
    assert.ok(!html.includes('__BUILD_ID__'));

    const policy = response.headers.get('content-security-policy');
    for (const directive of ["default-src 'self'", "script-src 'self'", "style-src 'self'", "connect-src 'self'", "object-src 'none'", "base-uri 'self'"]) {
      assert.ok(policy.split('; ').includes(directive), `the policy has ${directive}`);
    }
    assert.ok(!policy.includes('unsafe'));
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  }
});

test('modules, styles and fonts are served with their types and are never cached', async () => {
  for (const [address, type, start] of [
    ['/js/main.js', 'text/javascript; charset=utf-8', null],
    ['/js/main.js?v=dev', 'text/javascript; charset=utf-8', null],
    ['/assets/css/app.css', 'text/css; charset=utf-8', null],
    ['/assets/img/favicon.svg', 'image/svg+xml', '<svg'],
    ['/assets/fonts/Vazirmatn-Regular.woff2', 'font/woff2', 'wOF2'],
    ['/assets/fonts/OFL.txt', 'text/plain; charset=utf-8', null],
  ]) {
    const response = await fetch(`${origin}${address}`);
    assert.equal(response.status, 200, address);
    assert.equal(response.headers.get('content-type'), type, address);
    assert.equal(response.headers.get('cache-control'), 'no-store', address);
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff', address);
    const body = Buffer.from(await response.arrayBuffer());
    assert.ok(body.length > 0, address);
    if (start !== null) assert.equal(body.subarray(0, start.length).toString('latin1'), start, address);
  }

  // Modules are served unchanged: no stamping in development.
  const main = await (await fetch(`${origin}/js/main.js`)).text();
  assert.match(main, /from '\.\/app\.js'/);

  const head = await fetch(`${origin}/js/main.js`, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-type'), 'text/javascript; charset=utf-8');
  assert.equal(await head.text(), '');
});

test('only files of the sources are served', async () => {
  assert.equal((await fetch(`${origin}/js/no-such-module.js`)).status, 404);
  assert.equal((await fetch(`${origin}/js`)).status, 404, 'a directory is not a page');
  assert.equal((await fetch(`${origin}/js/`)).status, 404);
  assert.equal((await fetch(`${origin}/shipments`)).status, 404, 'routes live behind "#"; there is nothing to rewrite');
  assert.equal((await fetch(`${origin}/%E0%A4%A`)).status, 400, 'a broken escape sequence');
  assert.equal((await fetch(`${origin}/js/main.js%00.txt`)).status, 400);

  // package.json sits next to src/: none of these spellings may reach it.
  for (const escape of ['/../package.json', '/js/../../package.json', '/..%2fpackage.json', '/%2e%2e/package.json', '/%2E%2E%2Fpackage.json', '/js/..%2f..%2fpackage.json']) {
    const response = await rawGet(origin, escape);
    assert.equal(response.status, 403, escape);
    assert.ok(!response.body.includes('armin-transport-web'), `${escape} leaked package.json`);
  }
  // Spellings that stay inside the sources are simply looked up there.
  for (const inside of ['//package.json', '/..%5cpackage.json', '/js/../package.json', 'http://example.com/package.json']) {
    const response = await rawGet(origin, inside);
    assert.equal(response.status, 404, inside);
  }
  assert.equal((await rawGet(origin, '/js/../index.html')).status, 200);

  for (const method of ['POST', 'PUT', 'DELETE']) {
    const response = await fetch(`${origin}/index.html`, { method });
    assert.equal(response.status, 405, method);
  }
});

test('requests under /api are forwarded to the backend as they are and its answers come back unchanged', async () => {
  seen.length = 0;
  const listed = await fetch(`${origin}/api/v1/shipments?page=2&q=%D8%A8%D8%A7%D8%B1`, { headers: { Authorization: 'Bearer token-1', 'X-Request-ID': 'req-1' } });
  assert.equal(listed.status, 200);
  assert.equal(listed.headers.get('x-request-id'), 'req-from-backend');
  assert.equal(listed.headers.get('content-security-policy'), null, 'the headers of an API response are those of the backend');
  assert.equal((await listed.json()).message, 'پاسخ سرور');
  assert.equal(seen[0].method, 'GET');
  assert.equal(seen[0].url, '/api/v1/shipments?page=2&q=%D8%A8%D8%A7%D8%B1');
  assert.equal(seen[0].headers.authorization, 'Bearer token-1');
  assert.equal(seen[0].headers['x-request-id'], 'req-1');
  assert.equal(seen[0].headers.host, new URL(backendUrl).host, 'the backend sees its own host name');

  const payload = JSON.stringify({ username: 'armin.operator', password: 'رمز عبور آزمایشی' });
  const created = await fetch(`${origin}/api/v1/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: payload });
  assert.equal(created.status, 201);
  assert.equal(seen[1].method, 'POST');
  assert.equal(seen[1].headers['content-type'], 'application/json');
  assert.equal(seen[1].body, payload);

  // An upload: a body that is not text arrives byte for byte.
  const bytes = Buffer.from(Array.from({ length: 70_000 }, (_, index) => index % 256));
  const uploaded = await fetch(`${origin}/api/v1/shipments/1/documents`, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: bytes });
  assert.equal(uploaded.status, 201);
  assert.ok(seen[2].raw.equals(bytes));

  const missing = await fetch(`${origin}/api/v1/missing`);
  assert.equal(missing.status, 404, 'error statuses pass through');
  assert.equal((await missing.json()).success, false);

  const download = await fetch(`${origin}/api/v1/documents/7/download`);
  assert.equal(download.headers.get('content-type'), 'application/pdf');
  assert.equal(download.headers.get('content-disposition'), 'attachment; filename="bill.pdf"');
  assert.deepEqual([...Buffer.from(await download.arrayBuffer())], [0x25, 0x50, 0x44, 0x46, 0x00, 0xff, 0xfe]);

  for (const method of ['PATCH', 'DELETE']) {
    seen.length = 0;
    await fetch(`${origin}/api/v1/companies/3`, { method });
    assert.equal(seen[0].method, method);
  }

  // Only /api is forwarded: a file whose name merely starts like it is looked up in the sources.
  seen.length = 0;
  assert.equal((await fetch(`${origin}/apix`)).status, 404);
  assert.equal(seen.length, 0);
});

test('when the backend is not running the client gets an error in the envelope of the API', async () => {
  const closed = http.createServer();
  const closedUrl = await listen(closed);
  await close(closed);

  const lonely = createDevServer({ sourceDir: SOURCES, backendUrl: closedUrl });
  const lonelyOrigin = await listen(lonely);
  try {
    const response = await fetch(`${lonelyOrigin}/api/v1/health`);
    assert.equal(response.status, 502);
    assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8');
    const body = await response.json();
    assert.equal(body.success, false);
    assert.equal(body.data, null);
    assert.equal(body.errors.code, 'backend_unreachable');
    assert.match(body.message, /سرور برنامه در دسترس نیست/);
    // The page itself still loads, so the developer sees the message in the application.
    assert.equal((await fetch(`${lonelyOrigin}/`)).status, 200);
  } finally {
    await close(lonely);
  }
});

test('the address of the backend must be an http(s) URL', () => {
  assert.throws(() => createDevServer({ sourceDir: SOURCES, backendUrl: 'ftp://127.0.0.1/' }), /BACKEND_URL must be an http\(s\) URL/);
  assert.throws(() => createDevServer({ sourceDir: SOURCES, backendUrl: 'localhost:5000' }), /BACKEND_URL must be an http\(s\) URL/);
  assert.throws(() => createDevServer({ sourceDir: SOURCES, backendUrl: 'not a url' }), /BACKEND_URL must be an http\(s\) URL .* \(got "not a url"\)/);
  createDevServer({ sourceDir: SOURCES, backendUrl: 'https://api.example.com' });
});
