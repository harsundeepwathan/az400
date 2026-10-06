# Vector API

One small Node service in front of PostgreSQL. It exists so that:

- no AI key ships in the app,
- AI usage can be limited, measured and paid for per user,
- Pro is verified on the server, not trusted from the device,
- users can delete their account and data.

Training and food logs are **not** stored here. They stay on the user's devices and in their iCloud (see `docs/05-launch-audit.md`).

```
iOS ──HTTPS + Bearer──► vector-api (Node 20+) ──► PostgreSQL (Supabase or any managed Postgres)
                              └──► Claude (meal photos, coach summaries; structured output)
App Store ──Server Notifications V2──► vector-api
```

Sized for 100 → 10,000 users: one instance (two for redundancy), a 10-connection pool, no Redis, no queue. Quotas and rate limits live in Postgres, so they hold across instances.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | – | Liveness plus database check |
| POST | `/v1/auth/apple` | – | `{identity_token, nonce?}` → `{access_token (1 h), refresh_token, user_id}` |
| POST | `/v1/auth/refresh` | – | Rotates the refresh token. Reusing an old one revokes the whole token family |
| POST | `/v1/auth/sign-out` | Bearer | Revokes all refresh tokens |
| GET | `/v1/me` | Bearer | Entitlement, scan allowance, analytics preference |
| PATCH | `/v1/me` | Bearer | `{analytics_opt_out}`. Opting out also deletes stored events |
| DELETE | `/v1/me` | Bearer | Deletes the account and all personal data |
| POST | `/v1/subscription/transactions` | Bearer | `{signed_transaction}` (StoreKit 2 JWS) → entitlement. 403 if it belongs to another existing account |
| POST | `/v1/apple/notifications` | – (Apple JWS) | App Store Server Notifications V2 `{signedPayload}` → `{status: applied \| unlinked \| ignored \| duplicate}`. 400 if it doesn't name this app's bundle id |
| POST | `/v1/coach/summary` | Bearer, Pro | `{digest}` → `{summary, cached, generated_at}`. Contract: `docs/tasks/p1-tasklist.md` |
| POST | `/v1/meal-scan` | Bearer | `{image: base64 JPEG}` → `{scan_id, items, allowance}` |
| POST | `/v1/meal-scans/:id/correction` | Bearer | How the user corrected the estimate (no image) |
| POST | `/v1/events` | Bearer | Batched analytics events, at most 100. Names are allow-listed |

Errors are `{"error": "<code>"}` plus details where useful. Notable codes:
- `scan_quota_exceeded` (402), which comes with `allowance.resets_at`
- `daily_scan_limit`, `rate_limited` (429)
- `purchase_verification_unavailable` (503)
- `pro_required` (402), `busy` (503) from the coach summary
- `invalid_notification` (400) with a `reason` (`untrusted_root`, `signature`, `bundle`, `environment`, …)

## AI cost control

- **Quotas:** free gets 3 scans per rolling 7 days. Pro gets 30 a day as a fair-use ceiling. Every user has a burst limit of 4 a minute. Limits are checked and a slot reserved under a per-user advisory lock, so parallel requests can't slip past (there is a test).
- **What counts:** successful scans and "no food" results count against the quota. Errors and refusals don't.
- **Caching:** the same photo within 24 hours returns the stored result without calling Claude and without using quota.
- **Validation:** JPEG, PNG, WebP or GIF only (magic bytes), at most 3 MB decoded. The app sends 1024 px JPEGs at 0.7 quality, about 150–400 KB.
- **Accounting:** every call stores tokens (input, output, cache read and write), the model that served it, latency and cost in `ai_requests`. Images are never stored, only a SHA-256 for the cache.
- **No hidden retries:** both Claude calls pass `maxRetries: 0` with their timeout (meal scan 45 s, coach 30 s), so the SDK never makes a second paid call behind one reserved quota slot. A failed scan returns 503 `busy` and the app can retry, which goes through the quota again.
- **Monitoring:** see "Cost dashboard" below.
- **Prices** come from `PRICE_*_PER_MTOK`. The defaults ($5 input, $25 output, cache read 0.1×, cache write 1.25×) must be checked against the current Claude price list for the model you deploy.

## Coach summary

`POST /v1/coach/summary` turns a structured digest of the user's own logged data (built on the device; the server never sees the logs) into a 2–4 sentence summary.

- **Pro only**, checked against verified `subscriptions` rows (402 `pro_required` otherwise).
- **Validation:** zod schema matching the shared contract. Nullable fields accept `null` or a missing key (Swift's synthesized `Encodable` omits nil optionals). Unknown keys are dropped before the prompt.
- **Once per UTC day:** the first success is stored in `coach_summaries` (unique `user_id, day`) and returned with `cached: true` for the rest of the day, without a model call. Only the summary text is stored, never the digest.
- **Cost bounds:** a per-user advisory lock and a pending-row check stop parallel requests paying twice (429 `rate_limited`), and at most 4 model calls per user per UTC day (two failed requests with their retries). The retry after a rejected draft is reserved under the same lock and re-checks the cap (and that no other generation is in flight); if it would exceed the cap it is skipped and the request returns 503 `busy`. Recording a call and storing the accepted summary happen in one transaction under that lock, so a parallel request never sees the call finished but the summary missing. Each call has a 30 s timeout with SDK retries off, and the pending window is 3 minutes, longer than the worst case of one request (two attempts × 30 s).
- **Prompt:** byte-stable system prompt with `cache_control`, structured output `{summary}`, `max_tokens` 1024, effort `low`, the same model, beta and fallback setup as the meal scan. Claude only caches prompts above a model-specific minimum length, so check `cache_read_tokens` before counting on it.
- **Post-validation:** at most 600 characters, and every number in the text must appear in the digest (digest values, their roundings to 0 or 1 decimal, numbers inside digest strings, and the 7/14/30-day windows; "1RM" is ignored, "2,240" is read as 2240). A draft that fails is retried once with the reason; a second failure returns 503 `busy` and stores nothing. This is a simple numeric check: it doesn't catch numbers written as words or wrong claims made with real numbers.
- **Accounting:** every model call is its own `ai_requests` row (`kind = 'coach_summary'`), including rejected drafts (`status = 'error'`, `error_code = 'invented_number'` or `'summary_length'`). Cache hits are not recorded: they cost nothing, and a row per screen open would be an unbounded write per user. So `cache_hits` in the cost views counts meal scans only (rows written before migration 005 may still include coach hits).

## Cost dashboard

Views (migration `004_cost_views.sql`; `005` sets `security_invoker = true` on every cost view, so a role reading a view also needs `select` on the underlying tables and their row level security applies); months and windows are UTC, 30-day windows are relative to `now()`:

```sql
-- Spend per month and tier, split by feature
select * from ai_cost_by_month order by month desc, tier;
-- 30-day spend per active user (last_seen_at in 30 days) and per AI user, for free, pro and all
select * from ai_cost_per_active_user_30d;
-- 100 most expensive users in 30 days (user id only: pseudonymous, not anonymous, since it joins to users)
select * from ai_top_users_30d;
-- Meal scan failure / refusal / cache-hit rates, share corrected, mean absolute calorie error
select * from ai_scan_quality_30d;
-- Daily spend, scans and cost per scan, by tier (scans are meal scans only)
select * from ai_daily_cost order by day desc;
```

Definitions are commented in the migration. Spend is attributed to the tier recorded on each request; active users to their entitlement now. Deleted accounts' cost rows count in totals but not in per-user views. `ai_top_users_30d` is pseudonymous: the user id identifies an account, so grant it only to roles that may read `users`.

## App Store Server Notifications

Renewals, refunds, revocations, expiry, renewal-status changes, billing failures and grace periods update `subscriptions` without the app reopening.

**Setup:** App Store Connect → your app → App Information → App Store Server Notifications. Set the **Production Server URL** to `https://<api-host>/v1/apple/notifications` and choose **Version 2**. For TestFlight and sandbox, set the **Sandbox Server URL** to a deployment with `ALLOW_SANDBOX_PURCHASES=true` (the production API rejects sandbox notifications with 400). Use "Request a Test Notification" in App Store Connect (or the App Store Server API) to check delivery: a `TEST` notification is acknowledged as `ignored`. `APPLE_ROOT_CA_PATH` must be set, or the endpoint returns 503 so Apple retries later.

**Processing:**
- The outer `signedPayload`, `data.signedTransactionInfo` and `data.signedRenewalInfo` are each verified with the same certificate-chain check as purchases. Then bundle id and environment are checked on the notification and on the transaction. The notification must name this app: its bundle id comes from `data`, or for notifications without `data` from `summary` (`RENEWAL_EXTENSION` summaries) or `externalPurchaseToken`; a notification that names no bundle id, or another one, gets 400 `bundle`. The environment comes from `data` or `summary` (for `externalPurchaseToken`, an `externalPurchaseId` starting with `SANDBOX` is Sandbox); a missing environment, or a non-Production one without `ALLOW_SANDBOX_PURCHASES`, gets 400 `environment`.
- `notificationUUID` is stored in `apple_notifications`; a redelivery returns `duplicate` and changes nothing.
- Any notification carrying a Pro transaction is applied as that subscription's current state: expiry only moves forward, product and revocation come from the newest-signed transaction (so out-of-order deliveries or a stale JWS posted by the app can't undo a refund), and auto-renew and the billing grace period come from the newest renewal info. `REFUND` / `REVOKE` set `revoked_at` when the refunded transaction is for the current period (its `expiresDate` at or after the stored `expires_at`); a refund of an earlier period (say, last month's renewal) is logged (`apple_notification_revocation_kept_current_period`) and the current paid period is kept. A billing grace period keeps Pro until `grace_period_expires_at`.
- Handled types: `SUBSCRIBED`, `DID_RENEW`, `EXPIRED`, `REFUND`, `REVOKE`, `DID_CHANGE_RENEWAL_STATUS`, `DID_FAIL_TO_RENEW`, `GRACE_PERIOD_EXPIRED` (others carrying a transaction, such as `REFUND_REVERSED`, are applied the same way). Notifications without a transaction (`TEST`, summaries, external purchase tokens) or for non-Pro products are acknowledged as `ignored`, once their bundle id and environment pass.
- A transaction that isn't linked to a user is linked through `appAccountToken` (the user id the app sets when purchasing). Otherwise it is stored with `user_id` null (`unlinked`) and claimed by the first account that posts it to `/v1/subscription/transactions`. If its `appAccountToken` names another account that still exists, posting it is refused (403); if that account was deleted, the current user may claim the unlinked row, so a person who deleted their account and signs in again keeps the subscription they paid for. A row linked to a user is never moved.
- **Retention:** `apple_notifications` rows older than 90 days are deleted by the notification handler itself, at most once an hour per instance (an indexed delete of up to 10,000 rows; failures are logged and never fail the notification). Apple stops redelivering long before 90 days, so duplicate detection is unaffected.
- Every authentic payload gets 200. Forged, malformed, wrong-bundle and wrong-environment payloads get 400; a database outage gets 500, which Apple retries.

## Security

- **Sign in with Apple:** the identity token is verified against Apple's JWKS, issuer, audience (`APP_BUNDLE_ID`), expiry and nonce. Only Apple's stable `sub` is stored; no email and no name.
- **Tokens:** access tokens are HS256 and last 1 hour. Refresh tokens are 256-bit random values, stored as SHA-256 hashes, last 60 days, rotate on every use, and reuse is detected. A deleted account's access token stops working immediately.
- **Purchases:** the StoreKit JWS `x5c` chain must end in the exact Apple Root CA G3 you configure. Each certificate must be valid at signing and signed by the next, and the leaf and intermediate must carry Apple's marker OIDs. Then the ES256 signature is verified, followed by bundle, product, environment and `appAccountToken` (set it to the user id when purchasing). A transaction can't be moved to another account.
- **Rate limits for unauthenticated endpoints:** per instance and per client IP (20 a minute for auth, 300 for Apple notifications). Each limiter holds at most 50,000 addresses; when full it prunes expired windows (at most once a second), and if still full a new address gets 429 rather than growing memory.
- **Logs:** one JSON line per request (id, path, status, latency, user id). Bodies, tokens and images are never logged.
- **Privacy:** account deletion cascades through tokens, subscriptions, scans, corrections, coach summaries and events. `apple_notifications` holds no user id (type, environment, original transaction id, dates) and is pruned automatically after 90 days (see "Retention" above). A notification for a deleted account's transaction re-creates an unlinked subscription row with no personal data, which the same person can claim again after signing in. AI cost rows are kept with `user_id` cleared, so spend reporting stays correct without personal data.

## Configuration

| Variable | Required | Notes |
|---|---|---|
| `DATABASE_URL` | yes | Postgres connection string (Supabase: use the pooled URL) |
| `JWT_SECRET` | yes | ≥ 32 random bytes, e.g. `openssl rand -base64 48` |
| `APP_BUNDLE_ID` | yes | e.g. `app.vector.ios` |
| `PRO_PRODUCT_IDS` | yes | Comma-separated StoreKit product ids |
| `ANTHROPIC_API_KEY` | yes | Read by the Anthropic SDK |
| `APPLE_ROOT_CA_PATH` | for purchases | Path to `AppleRootCA-G3.cer` from https://www.apple.com/certificateauthority/. Without it, purchase verification returns 503 |
| `ALLOW_SANDBOX_PURCHASES` | no | `true` for TestFlight and development |
| `FREE_SCANS_PER_WEEK`, `PRO_SCANS_PER_DAY`, `SCANS_PER_MINUTE` | no | 3, 30, 4 |
| `PRICE_INPUT_PER_MTOK`, `PRICE_OUTPUT_PER_MTOK`, `PRICE_CACHE_READ_PER_MTOK`, `PRICE_CACHE_WRITE_PER_MTOK` | no | See "AI cost control" |
| `CLAUDE_MODEL` | no | Default `claude-opus-5-5` |
| `TRUST_PROXY` | no | `true` behind a load balancer, so client IPs (for the auth and notification rate limits) come from `X-Forwarded-For`. Only the entries appended by your own proxies are trusted: the client IP is the `TRUSTED_PROXY_HOPS`-th entry from the right, never the client-controlled leftmost one |
| `TRUSTED_PROXY_HOPS` | no | Number of proxies you run in front of the API that append to `X-Forwarded-For` (default 1, e.g. one load balancer; 2 for CDN plus load balancer) |
| `PORT` | no | 8787 |

Migrations in `migrations/` run automatically on start, under an advisory lock.

## Run and test

```sh
npm install
npm test                    # 59 tests; needs Postgres: TEST_DATABASE_URL (default postgres://vector:vector@localhost:5432/vector_test)
npm run build && npm start
```

Tests run against real PostgreSQL, one schema per file, covering:
- Sign in with Apple, using a locally generated JWKS
- refresh rotation and reuse detection
- quotas, including parallel requests
- caching, cost accounting and corrections
- StoreKit verification, with an OpenSSL-generated chain that carries Apple's marker OIDs
- App Store Server Notifications: renewal, refund and revocation, refund of an earlier period, grace period, duplicates, forged chains (outer and nested), wrong bundle and environment (including notifications without `data`), unlinked transactions, re-linking a deleted account's subscription, 90-day retention
- coach summary: Pro gating, validation, daily cache (no cost row per cache hit), cost rows, invented-number rejection and retry, the retry respecting the daily cap, no SDK retries, parallel requests (fake Claude client)
- client IP behind trusted proxies and the rate limiter's memory cap
- cost views, with known rows, and `security_invoker` on each view
- analytics validation and opt-out
- account deletion

## Not yet done (P1)

- **App Attest:** proves requests come from the genuine app.
- **Apple token revocation on account deletion:** this needs the Sign in with Apple REST API and a client secret.
