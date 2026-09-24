/**
 * Small in-memory fixed-window limiter for abuse protection on a single
 * instance (sign-in attempts). AI limits are enforced in the database instead
 * so they hold across instances.
 */
const buckets = new Map<string, { count: number; resetAt: number }>();

export function takeToken(key: string, limit: number, windowMs: number, now = Date.now()): boolean {
  const bucket = buckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowMs });
    if (buckets.size > 10_000) {
      for (const [k, b] of buckets) if (b.resetAt <= now) buckets.delete(k);
    }
    return true;
  }
  if (bucket.count >= limit) return false;
  bucket.count++;
  return true;
}
