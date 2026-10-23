import { createHash, timingSafeEqual } from "node:crypto";

// Comparing hashes gives equal-length buffers, so the comparison time does not show the token length.
const hash = (value: string) => createHash("sha256").update(value).digest();

/** True when the Authorization header has the expected bearer token. */
export function isAuthorized(header: string | undefined, token: string): boolean {
  const given = /^Bearer (.+)$/.exec(header ?? "")?.[1];
  return given !== undefined && token !== "" && timingSafeEqual(hash(given), hash(token));
}
