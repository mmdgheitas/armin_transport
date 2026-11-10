/**
 * Production build of the web client: `npm run build` → web/dist.
 *
 * There is no bundler. The sources are deployable as they are, so the build only
 *  1. copies src/ to dist/,
 *  2. stamps a content hash into every asset and module URL, so that after a deployment
 *     browsers always load one consistent set of files, and
 *  3. optionally points the client at another API origin (API_BASE_URL).
 *
 * Everything is checked before the output directory is touched, so a failed build
 * leaves the previous output as it was.
 *
 * Environment:
 *   API_BASE_URL  "/api/v1" (default) or an absolute URL such as "https://api.example.com/api/v1".
 *   OUT_DIR       output directory (default: dist). It is emptied first, so it must not exist yet,
 *                 be empty, or hold the output of an earlier build.
 */

import { createHash } from 'node:crypto';
import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const PROJECT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BUILD_ID_PLACEHOLDER = '__BUILD_ID__';
const CONFIG_MODULE = 'js/config.js';
const CONFIG_ENTRY = /apiBaseUrl:\s*'([^']*)'/;
// Static imports and re-exports of relative modules: "./x.js" becomes "./x.js?v=<id>".
const IMPORT_PATTERN = /(\bfrom\s+|\bimport\s+)(['"])(\.{1,2}\/[^'"]+?\.js)\2/g;
// The value is written into js/config.js as a string literal, so only plain URL characters are accepted.
const API_PATH_PATTERN = /^\/(?!\/)[A-Za-z0-9/_.~-]*$/; // a single leading slash: "//host" would be another origin
const API_URL_PATTERN = /^https?:\/\/[A-Za-z0-9.-]+(:\d{1,5})?(\/[A-Za-z0-9/_.~-]*)?$/;

/** A problem with the sources or the settings; its message is meant for the person running the build. */
export class BuildError extends Error {}

function fail(message) {
  throw new BuildError(message);
}

async function listFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = await Promise.all(
    entries.map((entry) => {
      const full = path.join(directory, entry.name);
      return entry.isDirectory() ? listFiles(full) : [full];
    }),
  );
  return files.flat().sort();
}

const relativeName = (base, file) => path.relative(base, file).split(path.sep).join('/');

/** True when `child` is `parent` itself or lies inside it. */
function contains(parent, child) {
  const relative = path.relative(parent, child);
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

/** The output directory is emptied before the build, so it has to be one this script may delete. */
async function checkOutDir(sourceDir, outDir) {
  if (contains(outDir, sourceDir)) fail(`The output directory (${outDir}) holds the sources; it would be emptied.`);
  if (contains(sourceDir, outDir)) fail(`The output directory (${outDir}) lies inside the sources.`);
  let entries;
  try {
    entries = await readdir(outDir);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    fail(`The output directory (${outDir}) cannot be read: ${error.message}`);
  }
  if (entries.length > 0 && !entries.includes('build.json')) {
    fail(`The output directory (${outDir}) is not empty and was not written by an earlier build. Empty it yourself or choose another directory.`);
  }
}

/** The API base URL to write into the client, or null to keep the one in src/js/config.js. */
function resolveApiBaseUrl(setting) {
  const value = (setting ?? '').trim();
  if (value === '') return null;
  const problem = `API_BASE_URL must be a path such as /api/v1 or a URL such as https://api.example.com/api/v1 (got "${value}").`;
  if (API_URL_PATTERN.test(value)) {
    if (!URL.canParse(value)) fail(problem); // a port above 65535, for example
  } else if (!API_PATH_PATTERN.test(value)) {
    fail(problem);
  }
  return value.replace(/\/+$/, '');
}

/** The page must work under the strict Content-Security-Policy sent by the backend. */
function checkIndexHtml(html) {
  if (/<script(?![^>]*\ssrc=)[^>]*>/i.test(html)) fail('index.html contains an inline <script>; the Content-Security-Policy forbids it.');
  if (/<style[\s>]/i.test(html)) fail('index.html contains a <style> element; the Content-Security-Policy forbids it.');
  if (/\sstyle\s*=/i.test(html)) fail('index.html contains an inline style attribute; the Content-Security-Policy forbids it.');
  if (/\son[a-z]+\s*=/i.test(html)) fail('index.html contains an inline event handler; the Content-Security-Policy forbids it.');
  if (!html.includes(BUILD_ID_PLACEHOLDER)) fail(`index.html does not reference ${BUILD_ID_PLACEHOLDER}.`);
}

/**
 * Builds `sourceDir` into `outDir` and returns `{ buildId, apiBaseUrl, files, modules, bytes }`.
 * Throws a `BuildError`, before anything is written, when the sources or the settings are not acceptable.
 */
export async function build({ sourceDir, outDir, apiBaseUrl: apiBaseUrlSetting = '' }) {
  // ---------------------------------------------------------------- checks
  let sourceFiles;
  try {
    sourceFiles = await listFiles(sourceDir);
  } catch (error) {
    fail(`The source directory (${sourceDir}) cannot be read: ${error.message}`);
  }
  const sourceNames = new Set(sourceFiles.map((file) => relativeName(sourceDir, file)));
  if (!sourceNames.has('index.html')) fail('index.html is missing from the sources.');
  if (!sourceNames.has(CONFIG_MODULE)) fail(`${CONFIG_MODULE} is missing from the sources.`);

  const apiBaseUrl = resolveApiBaseUrl(apiBaseUrlSetting);
  checkIndexHtml(await readFile(path.join(sourceDir, 'index.html'), 'utf8'));
  if (!CONFIG_ENTRY.test(await readFile(path.join(sourceDir, CONFIG_MODULE), 'utf8'))) fail(`${CONFIG_MODULE} has no apiBaseUrl entry.`);
  for (const file of sourceFiles.filter((name) => name.endsWith('.js'))) {
    if (/\bimport\s*\(/.test(await readFile(file, 'utf8'))) {
      fail(`${relativeName(sourceDir, file)} uses a dynamic import(); the build only versions static imports.`);
    }
  }
  await checkOutDir(sourceDir, outDir);

  // The build id is a hash of every source file and of the setting that changes the output.
  const hash = createHash('sha256');
  hash.update(`api=${apiBaseUrl === null ? 'source' : JSON.stringify(apiBaseUrl)}\n`);
  for (const file of sourceFiles) {
    hash.update(`${relativeName(sourceDir, file)}\n`);
    hash.update(await readFile(file));
  }
  const buildId = hash.digest('hex').slice(0, 12);

  // ---------------------------------------------------------------- output
  await rm(outDir, { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });
  await cp(sourceDir, outDir, { recursive: true });

  const indexPath = path.join(outDir, 'index.html');
  await writeFile(indexPath, (await readFile(indexPath, 'utf8')).replaceAll(BUILD_ID_PLACEHOLDER, buildId));

  // Version every module import so a new build never mixes with modules cached from the previous one.
  let modules = 0;
  let effectiveApiBaseUrl = null;
  for (const file of (await listFiles(outDir)).filter((name) => name.endsWith('.js'))) {
    let source = await readFile(file, 'utf8');
    source = source.replace(IMPORT_PATTERN, (_match, keyword, quote, specifier) => `${keyword}${quote}${specifier}?v=${buildId}${quote}`);
    if (relativeName(outDir, file) === CONFIG_MODULE) {
      if (apiBaseUrl !== null) source = source.replace(CONFIG_ENTRY, `apiBaseUrl: '${apiBaseUrl}'`);
      effectiveApiBaseUrl = CONFIG_ENTRY.exec(source)[1];
    }
    await writeFile(file, source);
    modules += 1;
  }

  // build.json is written last: it marks a complete build, and a directory that the next build may empty.
  const outputFiles = await listFiles(outDir);
  let bytes = 0;
  for (const file of outputFiles) bytes += (await stat(file)).size;
  const result = { buildId, apiBaseUrl: effectiveApiBaseUrl, files: outputFiles.length, modules, bytes };
  await writeFile(
    path.join(outDir, 'build.json'),
    `${JSON.stringify({ build_id: buildId, api_base_url: effectiveApiBaseUrl, files: result.files, bytes }, null, 2)}\n`,
  );
  return result;
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const outDir = path.resolve(PROJECT_DIR, process.env.OUT_DIR ?? 'dist');
  try {
    const result = await build({ sourceDir: path.join(PROJECT_DIR, 'src'), outDir, apiBaseUrl: process.env.API_BASE_URL });
    console.log(
      `built ${path.relative(PROJECT_DIR, outDir) || '.'}: ${result.files} files (${result.modules} modules), ${(result.bytes / 1024).toFixed(0)} KiB, build ${result.buildId}`,
    );
    console.log(`API base URL: ${result.apiBaseUrl === '' ? '(the root of this origin)' : result.apiBaseUrl}`);
  } catch (error) {
    if (!(error instanceof BuildError)) throw error;
    console.error(`build failed: ${error.message}`);
    process.exit(1);
  }
}
