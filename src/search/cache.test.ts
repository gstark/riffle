import { describe, expect, it } from "vitest";
import { cached } from "./cache.ts";

describe("cached", () => {
  it("loads once, then again after the time limit", async () => {
    let time = 0;
    let loads = 0;
    const get = cached(async () => ++loads, 100, () => time);

    expect(await get()).toBe(1);
    time = 99;
    expect(await get()).toBe(1);
    time = 100;
    expect(await get()).toBe(2);
  });

  it("does not keep a failed load", async () => {
    let fail = true;
    const get = cached(async () => {
      if (fail) throw new Error("boom");
      return "ok";
    }, 100);

    await expect(get()).rejects.toThrow("boom");
    fail = false;
    expect(await get()).toBe("ok");
  });
});
