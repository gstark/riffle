import { setTimeout } from "node:timers/promises";
import { describe, expect, it } from "vitest";
import { rateLimiter, runPool } from "./pool.ts";

describe("runPool", () => {
  it("runs every item and never exceeds the concurrency", async () => {
    let active = 0;
    let peak = 0;
    const seen: number[] = [];

    await runPool([1, 2, 3, 4, 5, 6, 7], 3, async (n) => {
      active++;
      peak = Math.max(peak, active);
      await setTimeout(5);
      seen.push(n);
      active--;
    });

    expect(seen.toSorted()).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(peak).toBe(3);
  });
});

describe("rateLimiter", () => {
  it("spaces calls by 1/perSecond seconds", async () => {
    const limit = rateLimiter(100);
    const started = Date.now();

    await Promise.all([limit(), limit(), limit(), limit(), limit()]);

    // The first call is immediate; the next four wait 10 ms each.
    expect(Date.now() - started).toBeGreaterThanOrEqual(39);
  });
});
