import { setTimeout } from "node:timers/promises";

/** Runs `task` for each item, with at most `concurrency` tasks at the same time. */
export async function runPool<T>(
  items: Iterable<T>,
  concurrency: number,
  task: (item: T) => Promise<void>,
): Promise<void> {
  const iterator = items[Symbol.iterator]();
  const worker = async () => {
    for (let next = iterator.next(); !next.done; next = iterator.next()) {
      await task(next.value);
    }
  };
  await Promise.all(Array.from({ length: concurrency }, worker));
}

/** Returns a function that resolves at most `perSecond` times each second. */
export function rateLimiter(perSecond: number): () => Promise<void> {
  const interval = 1000 / perSecond;
  let nextSlot = 0;
  return async () => {
    const now = Date.now();
    const slot = Math.max(now, nextSlot);
    nextSlot = slot + interval;
    if (slot > now) await setTimeout(slot - now);
  };
}
