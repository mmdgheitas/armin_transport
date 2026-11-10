/**
 * Launches headless Chrome for the end-to-end tests.
 *
 * Executable lookup order: CHROME_PATH → a system-wide Chrome/Chromium → the optional
 * @sparticuz/chromium package (a self-contained build for machines without a browser).
 */

import { existsSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

import puppeteer from 'puppeteer-core';

import { WEB_ROOT } from './backend.mjs';

export const SCREENSHOT_DIR = path.join(WEB_ROOT, 'test-results', 'screenshots');

const SYSTEM_BROWSERS = [
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
];

async function resolveBrowser() {
  if (process.env.CHROME_PATH) return { executablePath: process.env.CHROME_PATH, headless: true };
  const system = SYSTEM_BROWSERS.find((candidate) => existsSync(candidate));
  if (system) return { executablePath: system, headless: true };
  try {
    // The package only unpacks its bundled shared libraries when it believes it runs on AWS Lambda.
    process.env.AWS_EXECUTION_ENV ??= 'AWS_Lambda_nodejs22.x';
    const { default: chromium } = await import('@sparticuz/chromium');
    // Only the executable is used. The package's own argument list is tuned for AWS Lambda and
    // switches web security off, which would make the security checks of these tests meaningless.
    return { executablePath: await chromium.executablePath(), headless: 'shell' };
  } catch (error) {
    throw new Error('No browser found. Install Chrome, set CHROME_PATH, or install the optional dependency @sparticuz/chromium.', { cause: error });
  }
}

export async function launchBrowser() {
  const { executablePath, headless } = await resolveBrowser();
  await mkdir(SCREENSHOT_DIR, { recursive: true });
  return puppeteer.launch({
    executablePath,
    headless,
    // The sandbox needs kernel features that CI containers do not offer; the tests only load the local application.
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--font-render-hinting=none'],
    defaultViewport: { width: 1366, height: 900 },
  });
}
