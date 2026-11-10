import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { BuildError, build } from '../../scripts/build.mjs';

const WEB_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const REAL_SOURCES = path.join(WEB_DIR, 'src');

const scratch = await mkdtemp(path.join(os.tmpdir(), 'armin-web-build-'));
// Built modules are imported below; this marks the scratch directory as ES modules for every supported Node version.
await writeFile(path.join(scratch, 'package.json'), '{ "type": "module" }\n');
after(() => rm(scratch, { recursive: true, force: true }));

let counter = 0;
const freshDir = (label) => path.join(scratch, `${label}-${(counter += 1)}`);

async function listFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true, recursive: true });
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => path.relative(directory, path.join(entry.parentPath, entry.name)).split(path.sep).join('/'))
    .sort();
}

const VALID_SOURCES = {
  'index.html': '<!doctype html>\n<html><head><link rel="stylesheet" href="app.css?v=__BUILD_ID__" /><script type="module" src="js/main.js?v=__BUILD_ID__"></script></head><body></body></html>\n',
  'app.css': 'body { margin: 0; }\n',
  'js/config.js': "export const config = Object.freeze({\n  apiBaseUrl: '/api/v1',\n});\n",
  'js/main.js': "import { config } from './config.js';\nimport { helper } from './lib/helper.js';\n\nhelper(config);\n",
  'js/lib/helper.js': "export { config } from '../config.js';\nexport const helper = () => {};\n",
};

/** Writes a small source tree; `changes` replaces files (or removes them with `null`). */
async function sourceTree(changes = {}) {
  const directory = freshDir('src');
  for (const [name, content] of Object.entries({ ...VALID_SOURCES, ...changes })) {
    if (content === null) continue;
    await mkdir(path.dirname(path.join(directory, name)), { recursive: true });
    await writeFile(path.join(directory, name), content);
  }
  return directory;
}

async function rejects(options, messagePattern) {
  await assert.rejects(build(options), (error) => {
    assert.ok(error instanceof BuildError, `expected a BuildError, got ${error?.stack ?? error}`);
    assert.match(error.message, messagePattern);
    return true;
  });
}

test('the client builds: every page asset and module import carries the build stamp', async () => {
  const outDir = freshDir('out');
  const result = await build({ sourceDir: REAL_SOURCES, outDir });
  assert.match(result.buildId, /^[0-9a-f]{12}$/);
  assert.equal(result.apiBaseUrl, '/api/v1');

  const sourceFiles = await listFiles(REAL_SOURCES);
  const outputFiles = await listFiles(outDir);
  assert.deepEqual(outputFiles, [...sourceFiles, 'build.json'].sort());
  assert.equal(result.files, sourceFiles.length);

  const html = await readFile(path.join(outDir, 'index.html'), 'utf8');
  assert.ok(!html.includes('__BUILD_ID__'));
  assert.ok(html.includes(`src="js/main.js?v=${result.buildId}"`));
  assert.ok(html.includes(`href="assets/css/app.css?v=${result.buildId}"`));

  const modules = outputFiles.filter((name) => name.endsWith('.js'));
  assert.equal(result.modules, modules.length);
  let imports = 0;
  for (const name of modules) {
    const source = await readFile(path.join(outDir, name), 'utf8');
    for (const [, specifier] of source.matchAll(/(?:\bfrom|\bimport)\s*['"](\.[^'"]*)['"]/g)) {
      imports += 1;
      assert.match(specifier, new RegExp(`^\\.{1,2}/[\\w./-]+\\.js\\?v=${result.buildId}$`), `${name} imports ${specifier}`);
      // The stamp must not break the link: the imported file is part of the output.
      const target = path.posix.join(path.posix.dirname(name), specifier.split('?')[0]);
      assert.ok(outputFiles.includes(target), `${name} imports ${specifier}, which is not in the output`);
    }
  }
  assert.ok(imports > 50, `expected the modules to import each other, found ${imports} imports`);

  const manifest = JSON.parse(await readFile(path.join(outDir, 'build.json'), 'utf8'));
  assert.deepEqual(manifest, { build_id: result.buildId, api_base_url: '/api/v1', files: sourceFiles.length, bytes: result.bytes });

  // The sources themselves are never modified.
  assert.ok((await readFile(path.join(REAL_SOURCES, 'index.html'), 'utf8')).includes('__BUILD_ID__'));
});

test('the build id depends on the sources and on the API address, and on nothing else', async () => {
  const sourceDir = await sourceTree();
  const first = await build({ sourceDir, outDir: freshDir('out') });
  const again = await build({ sourceDir, outDir: freshDir('out') });
  assert.equal(again.buildId, first.buildId);

  const otherApi = await build({ sourceDir, outDir: freshDir('out'), apiBaseUrl: 'https://api.example.com/api/v1' });
  assert.notEqual(otherApi.buildId, first.buildId);
  const rootApi = await build({ sourceDir, outDir: freshDir('out'), apiBaseUrl: '/' });
  assert.notEqual(rootApi.buildId, first.buildId);

  const changed = await sourceTree({ 'app.css': 'body { margin: 1px; }\n' });
  assert.notEqual((await build({ sourceDir: changed, outDir: freshDir('out') })).buildId, first.buildId);
  const renamed = await sourceTree({ 'app.css': null, 'main.css': VALID_SOURCES['app.css'] });
  assert.notEqual((await build({ sourceDir: renamed, outDir: freshDir('out') })).buildId, first.buildId);
});

test('API_BASE_URL is written into the built configuration module', async () => {
  const sourceDir = await sourceTree();
  const cases = [
    [undefined, '/api/v1'],
    ['', '/api/v1'],
    ['   ', '/api/v1'],
    ['/backend/api/v1', '/backend/api/v1'],
    ['/backend/api/v1/', '/backend/api/v1'],
    ['/', ''],
    ['https://api.example.com/api/v1', 'https://api.example.com/api/v1'],
    ['  https://api.example.com/api/v1//  ', 'https://api.example.com/api/v1'],
    ['http://localhost:5000/api/v1', 'http://localhost:5000/api/v1'],
    ['https://api.example.com', 'https://api.example.com'],
  ];
  for (const [setting, expected] of cases) {
    const outDir = freshDir('out');
    const result = await build({ sourceDir, outDir, apiBaseUrl: setting });
    assert.equal(result.apiBaseUrl, expected, `API_BASE_URL=${JSON.stringify(setting)}`);
    // The built module is loaded for real: the value arrives intact and the file is still valid JavaScript.
    const { config } = await import(pathToFileURL(path.join(outDir, 'js', 'config.js')).href);
    assert.equal(config.apiBaseUrl, expected, `API_BASE_URL=${JSON.stringify(setting)}`);
    assert.equal(JSON.parse(await readFile(path.join(outDir, 'build.json'), 'utf8')).api_base_url, expected);
  }
  // The source keeps its own value.
  assert.equal(await readFile(path.join(sourceDir, 'js', 'config.js'), 'utf8'), VALID_SOURCES['js/config.js']);
});

test('an API_BASE_URL that is not a plain path or http(s) URL is refused and nothing is written', async () => {
  const sourceDir = await sourceTree();
  const refused = [
    'api/v1',
    '//evil.example/api/v1',
    '/\\evil.example/api',
    ['javascript', 'alert(1)'].join(':'),
    'ftp://files.example.com/api',
    'https://',
    'https://api.example.com/api/v1?debug=1',
    'https://api.example.com/api/v1#x',
    'https://user:secret@api.example.com/api/v1',
    'https://api.example.com:99999/api/v1',
    'https://api.example.com:port/api/v1',
    "/api/v1'; fetch('https://evil.example/'); '",
    '/api/v1\\',
    '/api v1',
    '/api/v1\n/x',
    '/آدرس',
    '${location.origin}/api',
  ];
  for (const value of refused) {
    const outDir = freshDir('out');
    await rejects({ sourceDir, outDir, apiBaseUrl: value }, /^API_BASE_URL must be a path such as \/api\/v1 or a URL such as /);
    assert.ok(!existsSync(outDir), `API_BASE_URL=${JSON.stringify(value)} left an output directory behind`);
  }
});

test('sources that would break under the Content-Security-Policy or escape the stamping are refused', async () => {
  const page = VALID_SOURCES['index.html'];
  const cases = [
    [{ 'index.html': page.replace('<body>', '<body><script>window.x = 1;</script>') }, /inline <script>/],
    [{ 'index.html': page.replace('<body>', '<body><SCRIPT type="module">import "./js/main.js";</SCRIPT>') }, /inline <script>/],
    [{ 'index.html': page.replace('</head>', '<style>body { color: red; }</style></head>') }, /<style> element/],
    [{ 'index.html': page.replace('<body>', '<body style="margin: 0">') }, /inline style attribute/],
    [{ 'index.html': page.replace('<body>', '<body onload="start()">') }, /inline event handler/],
    [{ 'index.html': page.replaceAll('?v=__BUILD_ID__', '') }, /does not reference __BUILD_ID__/],
    [{ 'index.html': null }, /index\.html is missing/],
    [{ 'js/config.js': null, 'js/main.js': 'export {};\n', 'js/lib/helper.js': 'export {};\n' }, /js\/config\.js is missing/],
    [{ 'js/config.js': 'export const config = Object.freeze({ apiBaseUrl: "/api/v1" });\n' }, /js\/config\.js has no apiBaseUrl entry/],
    [{ 'js/lib/helper.js': "export const helper = () => import('./late.js');\n" }, /js\/lib\/helper\.js uses a dynamic import\(\)/],
  ];
  for (const [changes, message] of cases) {
    const outDir = freshDir('out');
    await rejects({ sourceDir: await sourceTree(changes), outDir }, message);
    assert.ok(!existsSync(outDir), `${message} left an output directory behind`);
  }
  await rejects({ sourceDir: freshDir('no-such-src'), outDir: freshDir('out') }, /source directory .* cannot be read/);
});

test('a failed build keeps the previous output', async () => {
  const outDir = freshDir('out');
  const first = await build({ sourceDir: await sourceTree(), outDir });
  const before = await readFile(path.join(outDir, 'index.html'), 'utf8');

  const broken = await sourceTree({ 'js/main.js': "const load = () => import('./config.js');\nload();\n" });
  await rejects({ sourceDir: broken, outDir }, /dynamic import/);
  await rejects({ sourceDir: await sourceTree(), outDir, apiBaseUrl: 'not a url' }, /API_BASE_URL/);

  assert.equal(await readFile(path.join(outDir, 'index.html'), 'utf8'), before);
  assert.equal(JSON.parse(await readFile(path.join(outDir, 'build.json'), 'utf8')).build_id, first.buildId);
});

test('the output directory is emptied only when that is safe', async () => {
  const sourceDir = await sourceTree();
  const sourcesIntact = async () => assert.deepEqual(await listFiles(sourceDir), Object.keys(VALID_SOURCES).sort());

  await rejects({ sourceDir, outDir: sourceDir }, /holds the sources/);
  await sourcesIntact();
  await rejects({ sourceDir: path.join(sourceDir, 'js', '..'), outDir: sourceDir }, /holds the sources/);

  // Parents of the sources. Every path in this test lies in the scratch directory, so that a broken rule cannot
  // do harm; the same rule is what keeps `OUT_DIR=..` from emptying the project.
  const nested = path.join(freshDir('project'), 'web', 'src');
  await mkdir(path.dirname(nested), { recursive: true });
  for (const [name, content] of Object.entries(VALID_SOURCES)) {
    await mkdir(path.dirname(path.join(nested, name)), { recursive: true });
    await writeFile(path.join(nested, name), content);
  }
  await rejects({ sourceDir: nested, outDir: path.dirname(nested) }, /holds the sources/);
  await rejects({ sourceDir: nested, outDir: path.dirname(path.dirname(nested)) }, /holds the sources/);
  assert.deepEqual(await listFiles(nested), Object.keys(VALID_SOURCES).sort());

  await rejects({ sourceDir, outDir: path.join(sourceDir, 'dist') }, /lies inside the sources/);
  await sourcesIntact();

  // A directory with somebody else's files is left alone …
  const occupied = freshDir('occupied');
  await mkdir(occupied, { recursive: true });
  await writeFile(path.join(occupied, 'notes.txt'), 'keep me\n');
  await rejects({ sourceDir, outDir: occupied }, /not empty and was not written by an earlier build/);
  assert.equal(await readFile(path.join(occupied, 'notes.txt'), 'utf8'), 'keep me\n');
  const file = path.join(freshDir('plain'), 'file');
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, 'not a directory\n');
  await rejects({ sourceDir, outDir: file }, /cannot be read/);

  // … an empty one is filled, a directory whose name merely starts like the sources is fine …
  const empty = freshDir('empty');
  await mkdir(empty, { recursive: true });
  await build({ sourceDir, outDir: empty });
  await build({ sourceDir, outDir: `${sourceDir}-dist` });
  assert.ok(existsSync(path.join(`${sourceDir}-dist`, 'build.json')));

  // … and the output of an earlier build is replaced as a whole, stale files included.
  await writeFile(path.join(empty, 'js', 'removed-module.js'), 'export {};\n');
  await build({ sourceDir, outDir: empty });
  assert.deepEqual(await listFiles(empty), [...Object.keys(VALID_SOURCES), 'build.json'].sort());
});

test('npm run build reports the result, and a refused setting ends with an error message and exit code 1', () => {
  const script = path.join(WEB_DIR, 'scripts', 'build.mjs');
  const run = (env) => spawnSync(process.execPath, [script], { cwd: WEB_DIR, env: { ...process.env, ...env }, encoding: 'utf8' });

  const outDir = freshDir('cli');
  const built = run({ OUT_DIR: outDir, API_BASE_URL: 'https://api.example.com/api/v1/' });
  assert.equal(built.status, 0, built.stderr);
  assert.match(built.stdout, /^built .*: \d+ files \(\d+ modules\), \d+ KiB, build [0-9a-f]{12}\nAPI base URL: https:\/\/api\.example\.com\/api\/v1\n$/);
  assert.equal(built.stderr, '');
  assert.ok(existsSync(path.join(outDir, 'build.json')));

  const refusedDir = freshDir('cli');
  const refused = run({ OUT_DIR: refusedDir, API_BASE_URL: '//evil.example/api' });
  assert.equal(refused.status, 1);
  assert.match(refused.stderr, /^build failed: API_BASE_URL must be a path such as \/api\/v1/);
  assert.equal(refused.stdout, '');
  assert.ok(!existsSync(refusedDir));
});
