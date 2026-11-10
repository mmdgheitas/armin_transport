#!/usr/bin/env node
/**
 * Publishes text files as GitHub check-run outputs.
 *
 * Purpose: make CI diagnostics (analyzer output, build logs, test reports)
 * readable through the GitHub REST API (`GET /repos/{repo}/commits/{sha}/check-runs`)
 * in environments where the raw Actions log download host is not reachable.
 *
 * Usage: node tools/ci/publish-check.mjs <group> <file> [<file> ...]
 * Env:   GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA (set by GitHub Actions)
 *        PUBLISH_TAIL_CHARS (optional): keep only the last N characters per file.
 */
import { existsSync, readFileSync } from 'node:fs';
import { basename } from 'node:path';

const CHUNK_SIZE = 60000; // GitHub limits `output.text` to 65535 characters.
const [, , group, ...files] = process.argv;
const { GITHUB_TOKEN: token, GITHUB_REPOSITORY: repo, GITHUB_SHA: sha } = process.env;
const tailChars = Number.parseInt(process.env.PUBLISH_TAIL_CHARS ?? '0', 10);

if (!group || files.length === 0) {
  console.error('usage: publish-check.mjs <group> <file> [<file> ...]');
  process.exit(2);
}
if (!token || !repo || !sha) {
  console.error('GITHUB_TOKEN, GITHUB_REPOSITORY and GITHUB_SHA are required; skipping publish.');
  process.exit(0);
}

async function createCheckRun(name, title, summary, text) {
  const response = await fetch(`https://api.github.com/repos/${repo}/check-runs`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
      'User-Agent': 'armin-transport-ci',
    },
    body: JSON.stringify({
      name,
      head_sha: sha,
      status: 'completed',
      conclusion: 'neutral',
      output: { title, summary, text },
    }),
  });
  if (!response.ok) {
    throw new Error(`check-run creation failed: ${response.status} ${await response.text()}`);
  }
}

let failed = false;
for (const file of files) {
  if (!existsSync(file)) {
    console.warn(`skip (missing): ${file}`);
    continue;
  }
  let content = readFileSync(file, 'utf8');
  if (tailChars > 0 && content.length > tailChars) {
    content = content.slice(-tailChars);
  }
  if (content.length === 0) {
    content = '(empty)';
  }
  const total = Math.ceil(content.length / CHUNK_SIZE);
  for (let index = 0; index < total; index += 1) {
    const part = String(index + 1).padStart(3, '0');
    const name = `diag:${group}:${basename(file)}:${part}`;
    const chunk = content.slice(index * CHUNK_SIZE, (index + 1) * CHUNK_SIZE);
    try {
      await createCheckRun(name, `${basename(file)} [${index + 1}/${total}]`, `CI diagnostic output (${group}).`, chunk);
      console.log(`published ${name} (${chunk.length} chars)`);
    } catch (error) {
      failed = true;
      console.error(String(error));
    }
  }
}
process.exit(failed ? 1 : 0);
