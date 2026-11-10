/**
 * Development server: `npm run dev` serves src/ as it is and forwards /api to the backend,
 * so the browser talks to a single origin exactly as it does in production.
 *
 * Environment:
 *   PORT         port to listen on (default 5173)
 *   HOST         interface to bind (default 127.0.0.1; use 0.0.0.0 inside containers)
 *   BACKEND_URL  where the Flask API runs (default http://127.0.0.1:5000)
 *
 * Pages carry the same Content-Security-Policy as the backend sends for the built
 * client, so a violation shows up during development and not after deployment.
 * Nothing is cached, so a reload always shows the current sources.
 *
 * This server is a development tool: it has no TLS, no compression and no access log.
 */

import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
};

/** Sent with every page and file. The policy mirrors the one of the backend (tests/e2e/hosting.test.js compares them). */
export const SECURITY_HEADERS = Object.freeze({
  'Content-Security-Policy':
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; " +
    "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'no-store',
});

function sendText(response, status, text) {
  response.writeHead(status, { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' });
  response.end(text);
}

/** Forwards the request to the backend unchanged and streams the answer back. */
function proxy(backend, request, response) {
  const transport = backend.protocol === 'https:' ? https : http;
  const upstream = transport.request(
    {
      hostname: backend.hostname,
      port: backend.port || (backend.protocol === 'https:' ? 443 : 80),
      method: request.method,
      path: request.url,
      headers: { ...request.headers, host: backend.host },
    },
    (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode ?? 502, upstreamResponse.headers);
      upstreamResponse.pipe(response);
    },
  );
  upstream.on('error', (error) => {
    if (response.destroyed) return; // the browser has left already
    if (response.headersSent) {
      response.destroy(); // the answer broke off half-way; the browser reports a network error
      return;
    }
    // Same envelope as the API uses, so the client shows the message like any other error.
    response.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    response.end(
      JSON.stringify({
        success: false,
        message: 'سرور برنامه در دسترس نیست. آیا backend اجرا شده است؟',
        data: null,
        errors: { code: 'backend_unreachable', detail: error.message },
      }),
    );
  });
  // A request the browser gave up on (a page that was left) is not worth finishing.
  response.on('close', () => {
    if (!response.writableFinished) upstream.destroy();
  });
  request.pipe(upstream);
}

async function serveStatic(sourceDir, request, response) {
  // The path is taken literally (no URL resolution), then confined to the sources: whatever "..", "//" or
  // escaped separators it contains, the file that is opened lies inside `sourceDir`.
  let pathname;
  try {
    pathname = decodeURIComponent(request.url.split('?', 1)[0]);
  } catch {
    sendText(response, 400, 'Bad request');
    return;
  }
  if (pathname.includes('\0')) {
    sendText(response, 400, 'Bad request');
    return;
  }
  if (pathname === '/') pathname = '/index.html';
  const file = path.join(sourceDir, pathname);
  if (!file.startsWith(sourceDir + path.sep)) {
    sendText(response, 403, 'Forbidden');
    return;
  }
  try {
    const info = await stat(file);
    if (!info.isFile()) throw new Error('not a file');
    const type = CONTENT_TYPES[path.extname(file).toLowerCase()] ?? 'application/octet-stream';
    response.writeHead(200, { ...SECURITY_HEADERS, 'Content-Type': type });
    if (request.method === 'HEAD') {
      response.end();
    } else if (path.basename(file) === 'index.html') {
      response.end((await readFile(file, 'utf8')).replaceAll('__BUILD_ID__', 'dev'));
    } else {
      createReadStream(file)
        .on('error', () => response.destroy())
        .pipe(response);
    }
  } catch {
    sendText(response, 404, 'Not found');
  }
}

/** An HTTP server (not yet listening) that serves `sourceDir` and forwards /api to `backendUrl`. */
export function createDevServer({ sourceDir, backendUrl }) {
  const root = path.resolve(sourceDir);
  const backend = URL.canParse(backendUrl) ? new URL(backendUrl) : null;
  if (backend === null || (backend.protocol !== 'http:' && backend.protocol !== 'https:')) {
    throw new Error(`BACKEND_URL must be an http(s) URL such as http://127.0.0.1:5000 (got "${backendUrl}").`);
  }
  return http.createServer((request, response) => {
    if (request.url === '/api' || request.url.startsWith('/api/')) {
      proxy(backend, request, response);
    } else if (request.method === 'GET' || request.method === 'HEAD') {
      serveStatic(root, request, response);
    } else {
      sendText(response, 405, 'Method not allowed');
    }
  });
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const port = Number.parseInt(process.env.PORT ?? '5173', 10);
  const host = process.env.HOST ?? '127.0.0.1';
  const backendUrl = process.env.BACKEND_URL ?? 'http://127.0.0.1:5000';
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    console.error(`PORT must be a number between 0 and 65535 (got "${process.env.PORT}").`);
    process.exit(1);
  }
  let server;
  try {
    server = createDevServer({ sourceDir: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'src'), backendUrl });
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
  server.on('error', (error) => {
    console.error(error.code === 'EADDRINUSE' ? `Port ${port} is already in use. Choose another one with PORT=….` : `The server cannot start: ${error.message}`);
    process.exit(1);
  });
  server.listen(port, host, () => {
    const shownHost = host === '0.0.0.0' || host === '::' ? 'localhost' : host;
    console.log(`web client:  http://${shownHost}:${server.address().port}/`);
    console.log(`API proxy:   /api → ${new URL(backendUrl).origin}`);
  });
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => {
      server.close(() => process.exit(0));
      server.closeAllConnections(); // idle keep-alive connections would otherwise delay the exit
    });
  }
}
