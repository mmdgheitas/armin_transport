/**
 * A stand-in for `navigator.locks` (Web Locks) for the one thing this application locks:
 * the renewal of the session, which only one tab may do at a time.
 *
 * Browsers offer Web Locks only in a secure context (HTTPS or localhost). A server on a local
 * network is often reached over plain HTTP, and then the tabs coordinate through localStorage:
 * a tab takes the lock by writing a lease and checking a moment later that the lease is still
 * its own. When two tabs write at the same moment the last one wins, and once the storage has
 * settled both read the same owner. A lease runs out by itself, so a tab that was closed in the
 * middle blocks the others only for a short time.
 *
 * Only `request(name, [{ ifAvailable }], task)` is offered. Like the original, it calls
 * `task(lock)` once the lock is held, or `task(null)` without waiting when `ifAvailable` is set
 * and the lock is taken, and resolves to what the task returns.
 */

/** Longer than a renewal takes, even on a slow connection. */
export const LEASE_MS = 20_000;
/** Longer than the storage needs to carry a lease from one tab to the others. */
const CLAIM_SETTLE_MS = 80;
const POLL_MS = 100;

const realDelay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

export function createStorageLocks({ storage, now = () => Date.now(), delay = realDelay, tabId = Math.random().toString(36).slice(2) }) {
  let claims = 0;
  /** Per lock name: the requests of this tab that hold the lock or wait for it. They take turns among themselves. */
  const queues = new Map();

  const keyOf = (name) => `${name}.lease`;

  function read(name) {
    try {
      const lease = JSON.parse(storage.getItem(keyOf(name)) ?? 'null');
      return lease !== null && typeof lease === 'object' && typeof lease.owner === 'string' && typeof lease.until === 'number' ? lease : null;
    } catch {
      return null;
    }
  }

  function heldByAnother(name, owner) {
    const lease = read(name);
    return lease !== null && lease.owner !== owner && lease.until > now();
  }

  /** Resolves to whether `owner` holds the lease now. With `wait` it tries until it does. */
  async function acquire(name, owner, wait) {
    for (;;) {
      if (heldByAnother(name, owner)) {
        if (!wait) return false;
        await delay(POLL_MS);
        continue;
      }
      try {
        storage.setItem(keyOf(name), JSON.stringify({ owner, until: now() + LEASE_MS }));
      } catch {
        return true; // without a working storage there is nobody to coordinate with
      }
      await delay(CLAIM_SETTLE_MS);
      if (read(name)?.owner === owner) return true;
      if (!wait) return false;
    }
  }

  function release(name, owner) {
    try {
      if (read(name)?.owner === owner) storage.removeItem(keyOf(name));
    } catch {
      // The lease runs out by itself.
    }
  }

  return {
    request(name, optionsOrTask, maybeTask) {
      const task = typeof optionsOrTask === 'function' ? optionsOrTask : maybeTask;
      const ifAvailable = typeof optionsOrTask === 'object' && optionsOrTask !== null && optionsOrTask.ifAvailable === true;
      const queue = queues.get(name) ?? { length: 0, tail: Promise.resolve() };
      queues.set(name, queue);
      if (ifAvailable && queue.length > 0) return Promise.resolve().then(() => task(null));

      claims += 1;
      const owner = `${tabId}:${claims}`;
      queue.length += 1;
      const run = queue.tail.then(async () => {
        try {
          if (!(await acquire(name, owner, !ifAvailable))) return await task(null);
          try {
            return await task({ name });
          } finally {
            release(name, owner);
          }
        } finally {
          queue.length -= 1;
        }
      });
      queue.tail = run.catch(() => {});
      return run;
    },
  };
}
