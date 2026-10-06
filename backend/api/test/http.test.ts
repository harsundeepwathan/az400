import { test } from "node:test";
import assert from "node:assert/strict";
import { clientIp, HttpError, IpRateLimiter } from "../src/http.js";

const raw = (forwarded: string | string[] | undefined, remoteAddress = "10.0.0.2") =>
  ({ headers: forwarded === undefined ? {} : { "x-forwarded-for": forwarded }, socket: { remoteAddress } }) as any;

test("client IP: the socket address unless TRUST_PROXY, then the entry the trusted proxy added", () => {
  // Without TRUST_PROXY the header is client-controlled and ignored.
  assert.equal(clientIp(raw("6.6.6.6"), {}), "10.0.0.2");

  const proxied = { TRUST_PROXY: "true" };
  // The client prepends a fake address; one load balancer appends the real one on the right.
  assert.equal(clientIp(raw("6.6.6.6, 203.0.113.7"), proxied), "203.0.113.7");
  assert.equal(clientIp(raw("203.0.113.7"), proxied), "203.0.113.7");
  assert.equal(clientIp(raw(" 6.6.6.6 ,203.0.113.7 , "), proxied), "203.0.113.7", "whitespace and empty entries are ignored");
  assert.equal(clientIp(raw(["6.6.6.6", "203.0.113.7"]), proxied), "203.0.113.7", "repeated headers are joined in order");
  assert.equal(clientIp(raw(undefined), proxied), "10.0.0.2", "no header: socket address");

  // Two trusted hops (CDN, then load balancer): the second entry from the right.
  const twoHops = { TRUST_PROXY: "true", TRUSTED_PROXY_HOPS: "2" };
  assert.equal(clientIp(raw("6.6.6.6, 203.0.113.7, 198.51.100.1"), twoHops), "203.0.113.7");
  assert.equal(clientIp(raw("203.0.113.7"), twoHops), "203.0.113.7", "fewer entries than hops: the leftmost");
  // Invalid hop counts fall back to 1.
  assert.equal(clientIp(raw("6.6.6.6, 203.0.113.7"), { TRUST_PROXY: "true", TRUSTED_PROXY_HOPS: "0" }), "203.0.113.7");
  assert.equal(clientIp(raw("6.6.6.6, 203.0.113.7"), { TRUST_PROXY: "true", TRUSTED_PROXY_HOPS: "abc" }), "203.0.113.7");
});

test("IpRateLimiter limits per key and hard-caps how many keys it holds", () => {
  const limiter = new IpRateLimiter(2, 60_000, 3);
  const t = 1_000_000;
  limiter.check("a", t);
  limiter.check("a", t);
  assert.throws(() => limiter.check("a", t), (e: HttpError) => e.status === 429 && e.code === "rate_limited");

  limiter.check("b", t);
  limiter.check("c", t);
  assert.equal(limiter.size, 3);
  // Full, nothing expired: a new address is rejected instead of growing the map; known ones still work.
  assert.throws(() => limiter.check("d", t + 10), (e: HttpError) => e.status === 429 && e.details?.retry_after_seconds === 60);
  assert.equal(limiter.size, 3);
  limiter.check("b", t + 10);

  // Once windows expire, a full map is pruned and new addresses are admitted.
  limiter.check("d", t + 60_000);
  assert.equal(limiter.size, 1);
});
