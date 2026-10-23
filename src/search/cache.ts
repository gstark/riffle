/** Wraps `load` so that its result is used again for `ttlMs`. A failed load is not kept. */
export function cached<T>(load: () => Promise<T>, ttlMs: number, now = Date.now): () => Promise<T> {
  let entry: { value: T; loadedAt: number } | null = null;
  return async () => {
    if (entry && now() - entry.loadedAt < ttlMs) return entry.value;
    const value = await load();
    entry = { value, loadedAt: now() };
    return value;
  };
}
