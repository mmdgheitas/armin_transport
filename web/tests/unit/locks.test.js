import assert from 'node:assert/strict';
import { test } from 'node:test';

import { LEASE_MS, createStorageLocks } from '../../src/js/core/locks.js';
import { createMemoryStorage } from '../../src/js/core/session.js';
import { clock, laggingStorage, settle } from './helpers.js';

const NAME = 'renewal';
const LEASE_KEY = `${NAME}.lease`;

/** Time that only moves when `run()` lets the next waiting `delay()` go, so that waits in several tabs interleave as they would. */
function virtualTime() {
  const now = clock();
  const waits = [];
  const delay = (milliseconds) => new Promise((resolve) => waits.push({ at: now() + milliseconds, resolve }));
  async function run(limit = 120_000) {
    const end = now() + limit;
    for (;;) {
      await settle();
      waits.sort((a, b) => a.at - b.at);
      if (waits.length === 0 || waits[0].at > end) return;
      const next = waits.shift();
      now.advance(Math.max(0, next.at - now()));
      next.resolve();
    }
  }
  return { now, delay, run };
}

function browser() {
  const time = virtualTime();
  const storage = createMemoryStorage();
  const tab = (tabId, view = storage) => createStorageLocks({ storage: view, now: time.now, delay: time.delay, tabId });
  /** A task that takes `duration` and writes down when it ran. */
  const log = [];
  let active = 0;
  let most = 0;
  const work = (label, duration = 500) => async (lock) => {
    assert.notEqual(lock, null);
    active += 1;
    most = Math.max(most, active);
    log.push(`${label} starts`);
    await time.delay(duration);
    log.push(`${label} ends`);
    active -= 1;
    return label;
  };
  return { time, storage, tab, work, log, mostAtOnce: () => most };
}

test('runs the task with the lock, resolves to its result and leaves the lock free', async () => {
  const { time, storage, tab } = browser();
  const result = tab('a').request(NAME, async (lock) => {
    assert.deepEqual(lock, { name: NAME });
    assert.equal(JSON.parse(storage.getItem(LEASE_KEY)).owner, 'a:1');
    return 42;
  });
  await time.run();
  assert.equal(await result, 42);
  assert.equal(storage.getItem(LEASE_KEY), null);
});

test('tabs never run their tasks at the same time', async () => {
  const { time, tab, work, log, mostAtOnce } = browser();
  const results = Promise.all([tab('a').request(NAME, work('a')), tab('b').request(NAME, work('b')), tab('c').request(NAME, work('c'))]);
  await time.run();
  assert.deepEqual((await results).sort(), ['a', 'b', 'c']);
  assert.equal(mostAtOnce(), 1);
  assert.equal(log.length, 6);
  assert.deepEqual(log.slice(0, 2), ['a starts', 'a ends']);
});

test('when two tabs claim the lock at the same moment, the later claim wins and the other tab waits', async () => {
  const { time, storage, tab, work, log, mostAtOnce } = browser();
  // The second tab does not see the claim of the first one yet, as it happens between two browser tabs.
  const late = laggingStorage(storage, [LEASE_KEY]);
  const results = Promise.all([tab('a').request(NAME, work('a')), tab('b', late).request(NAME, work('b'))]);
  await time.run();
  assert.deepEqual(await results, ['a', 'b']);
  assert.deepEqual(log, ['b starts', 'b ends', 'a starts', 'a ends']);
  assert.equal(mostAtOnce(), 1);
  assert.equal(storage.getItem(LEASE_KEY), null);
});

test('with ifAvailable a taken lock is not waited for', async () => {
  const { time, tab, work, log } = browser();
  const first = tab('a').request(NAME, work('a', 5000));
  await time.run(1000);
  const second = tab('b').request(NAME, { ifAvailable: true }, async (lock) => (lock === null ? 'taken' : 'free'));
  await time.run(1000);
  assert.equal(await second, 'taken');
  assert.deepEqual(log, ['a starts']);
  await time.run();
  assert.equal(await first, 'a');
});

test('with ifAvailable a free lock is taken', async () => {
  const { time, tab, storage } = browser();
  const result = tab('a').request(NAME, { ifAvailable: true }, async (lock) => (lock === null ? 'taken' : 'free'));
  await time.run();
  assert.equal(await result, 'free');
  assert.equal(storage.getItem(LEASE_KEY), null);
});

test('the lease of a tab that was closed in the middle runs out', async () => {
  const { time, storage, tab, work } = browser();
  const start = time.now();
  storage.setItem(LEASE_KEY, JSON.stringify({ owner: 'closed:1', until: start + LEASE_MS }));
  const result = tab('a').request(NAME, work('a'));
  await time.run(LEASE_MS - 1000);
  assert.equal(JSON.parse(storage.getItem(LEASE_KEY)).owner, 'closed:1');
  await time.run();
  assert.equal(await result, 'a');
  assert.ok(time.now() - start >= LEASE_MS);
});

test('the requests of one tab take turns as well', async () => {
  const { time, tab, work, log, mostAtOnce } = browser();
  const locks = tab('a');
  const first = locks.request(NAME, work('first'));
  const second = locks.request(NAME, work('second'));
  const third = locks.request(NAME, { ifAvailable: true }, async (lock) => (lock === null ? 'taken' : 'free'));
  await time.run();
  assert.deepEqual([await first, await second, await third], ['first', 'second', 'taken']);
  assert.deepEqual(log, ['first starts', 'first ends', 'second starts', 'second ends']);
  assert.equal(mostAtOnce(), 1);
});

test('a task that fails gives the lock back', async () => {
  const { time, storage, tab, work } = browser();
  const failed = tab('a').request(NAME, async () => {
    throw new Error('renewal failed');
  });
  const next = tab('b').request(NAME, work('b'));
  await time.run();
  await assert.rejects(failed, /renewal failed/);
  assert.equal(await next, 'b');
  assert.equal(storage.getItem(LEASE_KEY), null);
});

test('without a usable storage the task simply runs', async () => {
  const { time } = browser();
  const broken = {
    getItem: () => null,
    setItem() {
      throw new Error('storage is blocked');
    },
    removeItem() {
      throw new Error('storage is blocked');
    },
  };
  const locks = createStorageLocks({ storage: broken, now: time.now, delay: time.delay, tabId: 'a' });
  const result = locks.request(NAME, async (lock) => (lock === null ? 'taken' : 'free'));
  await time.run();
  assert.equal(await result, 'free');
});

test('a lease that cannot be read counts as no lease', async () => {
  const { time, storage, tab, work } = browser();
  storage.setItem(LEASE_KEY, '{not json');
  const result = tab('a').request(NAME, work('a'));
  await time.run();
  assert.equal(await result, 'a');
});
