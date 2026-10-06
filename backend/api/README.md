# Vector API

One small Node service in front of PostgreSQL. It exists so that:

- no AI key ships in the app,
- AI usage can be limited, measured and paid for per user,
- Pro is verified on the server, not trusted from the device,
- users can delete their account and data.

Training and food logs are **not** stored here. They stay on the user's devices and in their iCloud (see `docs/05-launch-audit.md`).

```
iOS ──HTTPS + Bearer──► vector-api (Node 20+) ──► PostgreSQL (Supabase or any managed Postgres)
                              └──► Claude (meal photos, structured output)
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
| POST | `/v1/subscription/transactions` | Bearer | `{signed_transaction}` (StoreKit 2 JWS) → entitlement |
| POST | `/v1/meal-scan` | Bearer | `{image: base64 JPEG}` → `{scan_id, items, allowance}` |
| POST | `/v1/meal-scans/:id/correction` | Bearer | How the user corrected the estimate (no image) |
| POST | `/v1/events` | Bearer | Batched analytics events, at most 100. Names are allow-listed |

Errors are `{"error": "<code>"}` plus details where useful. Notable codes:
- `scan_quota_exceeded` (402), which comes with `allowance.resets_at`
- `daily_scan_limit`, `rate_limited` (429)
- `purchase_verification_unavailable` (503)

## AI cost control

- **Quotas:** free gets 3 scans per rolling 7 days. Pro gets 30 a day as a fair-use ceiling. Every user has a burst limit of 4 a minute. Limits are checked and a slot reserved under a per-user advisory lock, so parallel requests can't slip past (there is a test).
- **What counts:** successful scans and "no food" results count against the quota. Errors and refusals don't.
- **Caching:** the same photo within 24 hours returns the stored result without calling Claude and without using quota.
- **Validation:** JPEG, PNG, WebP or GIF only (magic bytes), at most 3 MB decoded. The app sends 1024 px JPEGs at 0.7 quality, about 150–400 KB.
- **Accounting:** every call stores tokens (input, output, cache read and write), the model that served it, latency and cost in `ai_requests`. Images are never stored, only a SHA-256 for the cache.
- **Monitoring:** `select * from ai_daily_cost order by day desc` gives scans, cache hits, failures, spend and cost per scan, by tier.
- **Prices** come from `PRICE_*_PER_MTOK`. The defaults ($5 input, $25 output, cache read 0.1×, cache write 1.25×) must be checked against the current Claude price list for the model you deploy.

## Security

- **Sign in with Apple:** the identity token is verified against Apple's JWKS, issuer, audience (`APP_BUNDLE_ID`), expiry and nonce. Only Apple's stable `sub` is stored; no email and no name.
- **Tokens:** access tokens are HS256 and last 1 hour. Refresh tokens are 256-bit random values, stored as SHA-256 hashes, last 60 days, rotate on every use, and reuse is detected. A deleted account's access token stops working immediately.
- **Purchases:** the StoreKit JWS `x5c` chain must end in the exact Apple Root CA G3 you configure. Each certificate must be valid at signing and signed by the next, and the leaf and intermediate must carry Apple's marker OIDs. Then the ES256 signature is verified, followed by bundle, product, environment and `appAccountToken` (set it to the user id when purchasing). A transaction can't be moved to another account.
- **Logs:** one JSON line per request (id, path, status, latency, user id). Bodies, tokens and images are never logged.
- **Privacy:** account deletion cascades through tokens, subscriptions, scans, corrections and events. AI cost rows are kept with `user_id` cleared, so spend reporting stays correct without personal data.

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
| `TRUST_PROXY` | no | `true` behind a load balancer, so client IPs come from `X-Forwarded-For` |
| `PORT` | no | 8787 |

Migrations in `migrations/` run automatically on start, under an advisory lock.

## Run and test

```sh
npm install
npm test                    # needs Postgres: TEST_DATABASE_URL (default postgres://vector:vector@localhost:5432/vector_test)
npm run build && npm start
```

Tests run against real PostgreSQL, one schema per file, covering:
- Sign in with Apple, using a locally generated JWKS
- refresh rotation and reuse detection
- quotas, including parallel requests
- caching, cost accounting and corrections
- StoreKit verification, with an OpenSSL-generated chain that carries Apple's marker OIDs
- analytics validation and opt-out
- account deletion

## Not yet done (P1)

- **App Store Server Notifications V2:** renewals, refunds and cancellations update `subscriptions` without the app reopening.
- **App Attest:** proves requests come from the genuine app.
- **Apple token revocation on account deletion:** this needs the Sign in with Apple REST API and a client secret.
