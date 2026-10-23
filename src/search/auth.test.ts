import { describe, expect, it } from "vitest";
import { isAuthorized } from "./auth.ts";

describe("isAuthorized", () => {
  it("accepts the expected bearer token", () => {
    expect(isAuthorized("Bearer s3cret", "s3cret")).toBe(true);
  });

  it.each<[string | undefined]>([[undefined], [""], ["s3cret"], ["Bearer "], ["Bearer wrong"], ["Basic s3cret"]])(
    "rejects %j",
    (header) => {
      expect(isAuthorized(header, "s3cret")).toBe(false);
    },
  );

  it("rejects everything when the expected token is empty", () => {
    expect(isAuthorized("Bearer ", "")).toBe(false);
  });
});
