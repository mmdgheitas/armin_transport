/**
 * Starts the real backend for the end-to-end tests.
 *
 * Nothing is mocked: a scratch MySQL database is created and migrated with Alembic,
 * demo data is seeded, and Gunicorn serves the API together with the built web client
 * (web/dist) in production mode, the same way a single-server deployment runs.
 *
 * Environment:
 *   E2E_DATABASE_URL  MySQL URL (falls back to TEST_DATABASE_URL). The database user must be allowed
 *                     to create and drop "<database>_e2e_<random>".
 *   BACKEND_PYTHON    Python interpreter that has the backend requirements installed
 *                     (default: backend/.venv/bin/python).
 */

import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const WEB_ROOT = path.resolve(here, '..', '..', '..');
export const REPO_ROOT = path.resolve(WEB_ROOT, '..');
const BACKEND_ROOT = path.join(REPO_ROOT, 'backend');

/** Password of every seeded demo account in the end-to-end environment. */
export const DEMO_PASSWORD = 'E2e-Demo-Passw0rd!';

const SCRATCH_DB_SCRIPT = `
import sys
import sqlalchemy as sa
from sqlalchemy.engine import make_url

action, url, name = sys.argv[1], make_url(sys.argv[2]), sys.argv[3]
engine = sa.create_engine(url, isolation_level="AUTOCOMMIT")
with engine.connect() as connection:
    if action == "create":
        connection.execute(sa.text(f"CREATE DATABASE \`{name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"))
    else:
        connection.execute(sa.text(f"DROP DATABASE IF EXISTS \`{name}\`"))
print(url.set(database=name).render_as_string(hide_password=False))
`;

function pythonPath() {
  const configured = process.env.BACKEND_PYTHON;
  const candidate = configured ?? path.join(BACKEND_ROOT, '.venv', 'bin', 'python');
  if (!configured && !existsSync(candidate)) {
    throw new Error(`No backend virtualenv at ${candidate}. Create it (see backend/README.md) or set BACKEND_PYTHON.`);
  }
  return candidate;
}

/** Runs a command to completion and resolves to its stdout; rejects with the combined output on failure. */
function run(command, args, { env, cwd = BACKEND_ROOT, input = null } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => (stdout += chunk));
    child.stderr.on('data', (chunk) => (stderr += chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve(stdout);
      else reject(new Error(`${command} ${args.join(' ')} exited with code ${code}\n${stdout}\n${stderr}`));
    });
    child.stdin.end(input ?? '');
  });
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function waitUntilReady(baseUrl, child, output) {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`The backend exited during start-up (code ${child.exitCode}).\n${output()}`);
    try {
      const response = await fetch(`${baseUrl}/api/v1/health/ready`);
      if (response.ok) return;
    } catch {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`The backend did not become ready within 60 seconds.\n${output()}`);
}

/**
 * Boots the backend. `settings` are extra environment variables for the application
 * (for example `{ EMPLOYEE_CAN_DELETE_DOCUMENTS: 'true' }`).
 * Resolves to `{ baseUrl, apiUrl, password, seedOutput, logs(), stop() }`.
 */
export async function startBackend(settings = {}) {
  const adminUrl = process.env.E2E_DATABASE_URL ?? process.env.TEST_DATABASE_URL;
  if (!adminUrl || !adminUrl.startsWith('mysql')) {
    throw new Error('Set E2E_DATABASE_URL (or TEST_DATABASE_URL) to a MySQL URL, e.g. mysql+pymysql://user:password@127.0.0.1:3306/armin_transport_test');
  }
  if (!existsSync(path.join(WEB_ROOT, 'dist', 'index.html'))) {
    throw new Error('web/dist is missing. Run "npm run build" before the end-to-end tests.');
  }

  const python = pythonPath();
  const baseEnv = { PATH: process.env.PATH ?? '', HOME: process.env.HOME ?? '', LANG: 'C.UTF-8', PYTHONUNBUFFERED: '1' };
  const databaseName = `${new URL(adminUrl.replace(/^mysql\+\w+:/, 'mysql:')).pathname.slice(1)}_e2e_${randomBytes(5).toString('hex')}`;
  const workDir = await mkdtemp(path.join(os.tmpdir(), 'armin-e2e-'));
  const port = await freePort();
  let child = null;
  let log = '';

  const dropDatabase = () => run(python, ['-', 'drop', adminUrl, databaseName], { env: baseEnv, input: SCRATCH_DB_SCRIPT });
  const cleanUp = async () => {
    await dropDatabase().catch((error) => console.error(`Could not drop ${databaseName}: ${error.message}`));
    await rm(workDir, { recursive: true, force: true });
  };

  try {
    const databaseUrl = (await run(python, ['-', 'create', adminUrl, databaseName], { env: baseEnv, input: SCRATCH_DB_SCRIPT })).trim();
    const env = {
      ...baseEnv,
      FLASK_APP: 'wsgi:app',
      APP_ENV: 'production',
      DATABASE_URL: databaseUrl,
      JWT_SECRET_KEY: randomBytes(48).toString('hex'),
      STORAGE_ROOT: path.join(workDir, 'storage'),
      SERVE_WEB_APP: 'true',
      WEB_APP_DIR: path.join(WEB_ROOT, 'dist'),
      HSTS_ENABLED: 'false', // plain http on localhost
      LOG_FORMAT: 'text',
      LOG_LEVEL: 'WARNING',
      // One browser on one address plays every user, so the per-address limits are lifted.
      RATE_LIMIT_LOGIN_IP: '5000/60',
      RATE_LIMIT_LOGIN_USER: '5000/60',
      RATE_LIMIT_REFRESH_IP: '5000/60',
      RATE_LIMIT_CUSTOMER_LOOKUP_IP: '5000/60',
      RATE_LIMIT_CUSTOMER_LOOKUP_FAILURES_IP: '5000/60',
      RATE_LIMIT_CUSTOMER_ACCESS_IP: '5000/60',
      BIND: `127.0.0.1:${port}`,
      WEB_CONCURRENCY: '2',
      GUNICORN_THREADS: '4',
      ...settings,
    };

    await run(python, ['-m', 'flask', 'db', 'upgrade'], { env });
    // The demo seeder refuses to run in production, so it runs in development mode against the same database.
    const seedOutput = await run(python, ['-m', 'flask', 'seed-demo', '--password', DEMO_PASSWORD], { env: { ...env, APP_ENV: 'development' } });

    child = spawn(python, ['-m', 'gunicorn', '-c', 'gunicorn.conf.py', 'wsgi:app'], { cwd: BACKEND_ROOT, env, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', (chunk) => (log += chunk));
    child.stderr.on('data', (chunk) => (log += chunk));
    const baseUrl = `http://127.0.0.1:${port}`;
    await waitUntilReady(baseUrl, child, () => log);

    return {
      baseUrl,
      apiUrl: `${baseUrl}/api/v1`,
      password: DEMO_PASSWORD,
      seedOutput,
      logs: () => log,
      async stop() {
        if (child.exitCode === null) {
          const exited = new Promise((resolve) => child.once('close', resolve));
          child.kill('SIGTERM');
          const timer = setTimeout(() => child.kill('SIGKILL'), 10_000);
          await exited;
          clearTimeout(timer);
        }
        await cleanUp();
      },
    };
  } catch (error) {
    if (child && child.exitCode === null) child.kill('SIGKILL');
    await cleanUp();
    throw error;
  }
}

/** Minimal API client for arranging test data and checking results behind the UI's back. */
export function apiClient(apiUrl) {
  async function call(method, route, { token = null, json = undefined } = {}) {
    const response = await fetch(`${apiUrl}${route}`, {
      method,
      headers: { Accept: 'application/json', ...(json === undefined ? {} : { 'Content-Type': 'application/json' }), ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: json === undefined ? undefined : JSON.stringify(json),
    });
    const body = await response.json();
    if (!response.ok) throw new Error(`${method} ${route} → ${response.status} ${JSON.stringify(body)}`);
    return body.data;
  }
  return {
    call,
    async login(username, password = DEMO_PASSWORD) {
      return (await call('POST', '/auth/login', { json: { username, password } })).access_token;
    },
    /** Every item of a paginated collection. */
    async list(route, token) {
      const items = [];
      for (let page = 1; ; page += 1) {
        const data = await call('GET', `${route}${route.includes('?') ? '&' : '?'}page=${page}&per_page=100`, { token });
        items.push(...data.items);
        if (!data.pagination.has_next) return items;
      }
    },
    /** Uploads `files` (`[{ name, content, type }]`) to a shipment and resolves to the created documents. */
    async upload(shipmentId, token, files, { customerVisible = true } = {}) {
      const form = new FormData();
      for (const file of files) form.append('files', new Blob([file.content], { type: file.type }), file.name);
      form.append('customer_visible', customerVisible ? 'true' : 'false');
      const response = await fetch(`${apiUrl}/shipments/${shipmentId}/documents`, {
        method: 'POST',
        headers: { Accept: 'application/json', Authorization: `Bearer ${token}` },
        body: form,
      });
      const body = await response.json();
      if (!response.ok) throw new Error(`upload → ${response.status} ${JSON.stringify(body)}`);
      return body.data;
    },
  };
}
