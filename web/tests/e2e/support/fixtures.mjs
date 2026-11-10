/** Small real files for upload scenarios, written to a temporary directory for the duration of a test file. */

import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after } from 'node:test';

export const PDF_BYTES = Buffer.from('%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n', 'latin1');
export const PNG_BYTES = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
export const TEXT_BYTES = Buffer.from('یادداشت داخلی: بار با دو کامیون ارسال می‌شود.\n', 'utf8');

/**
 * Returns `file(name, content)`, which writes a file and resolves to its path.
 * The directory is created on first use, so nothing here depends on the order of `before` hooks.
 */
export function useFiles() {
  let directory = null;
  after(async () => {
    if (directory) await rm(await directory, { recursive: true, force: true });
  });
  return async function file(name, content) {
    directory ??= mkdtemp(path.join(os.tmpdir(), 'armin-e2e-files-'));
    const target = path.join(await directory, name);
    await writeFile(target, content);
    return target;
  };
}
