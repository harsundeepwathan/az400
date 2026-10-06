-- Vector API schema. The server stores only what it needs to run the
-- service: identity, verified subscriptions, AI usage and cost, scan results
-- and corrections, and product analytics. Training and food logs stay on the
-- user's devices and iCloud. Meal photos are never stored.

create table users (
  id uuid primary key default gen_random_uuid(),
  apple_sub text not null unique check (length(apple_sub) between 1 and 255),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  analytics_opt_out boolean not null default false
);

-- Rotating refresh tokens. Only a SHA-256 hash is stored. Reusing a rotated
-- token revokes its whole family (stolen-token detection).
create table refresh_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  family_id uuid not null,
  token_hash bytea not null unique check (length(token_hash) = 32),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  check (expires_at > created_at)
);
create index refresh_tokens_user_idx on refresh_tokens (user_id);
create index refresh_tokens_family_idx on refresh_tokens (family_id);

-- StoreKit 2 transactions verified against Apple's certificate chain.
create table subscriptions (
  original_transaction_id text primary key check (length(original_transaction_id) between 1 and 64),
  user_id uuid not null references users(id) on delete cascade,
  product_id text not null check (length(product_id) between 1 and 255),
  environment text not null check (environment in ('Production', 'Sandbox', 'Xcode', 'LocalTesting')),
  purchased_at timestamptz not null,
  expires_at timestamptz,
  revoked_at timestamptz,
  updated_at timestamptz not null default now()
);
create index subscriptions_user_idx on subscriptions (user_id);

-- One row per AI call (or rejected attempt): the basis for quotas, rate
-- limits and cost monitoring. Rows survive account deletion with user_id
-- cleared, so aggregate cost history stays accurate without personal data.
create table ai_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete set null,
  kind text not null check (kind in ('meal_scan')),
  status text not null check (status in ('pending', 'ok', 'no_food', 'refused', 'error', 'cached')),
  tier text not null check (tier in ('free', 'pro')),
  model text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  cache_read_tokens integer not null default 0 check (cache_read_tokens >= 0),
  cache_write_tokens integer not null default 0 check (cache_write_tokens >= 0),
  cost_usd numeric(12, 6) not null default 0 check (cost_usd >= 0),
  latency_ms integer check (latency_ms >= 0),
  image_bytes integer check (image_bytes >= 0),
  image_sha256 bytea check (image_sha256 is null or length(image_sha256) = 32),
  error_code text,
  created_at timestamptz not null default now()
);
create index ai_requests_user_time_idx on ai_requests (user_id, created_at desc);
create index ai_requests_time_idx on ai_requests (created_at);
create index ai_requests_cache_idx on ai_requests (user_id, image_sha256) where status = 'ok';

-- What the model returned and how the user corrected it. Used to measure
-- and improve scan accuracy. No image.
create table meal_scans (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references ai_requests(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  items jsonb not null check (jsonb_typeof(items) = 'array'),
  correction jsonb check (correction is null or jsonb_typeof(correction) = 'object'),
  corrected_at timestamptz,
  created_at timestamptz not null default now()
);
create index meal_scans_user_idx on meal_scans (user_id, created_at desc);

-- Product analytics. Client-generated ids make batch uploads idempotent.
create table analytics_events (
  id uuid primary key,
  user_id uuid references users(id) on delete cascade,
  name text not null check (name ~ '^[a-z][a-z0-9_]{1,63}$'),
  properties jsonb not null default '{}' check (jsonb_typeof(properties) = 'object'),
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  app_version text check (app_version is null or length(app_version) <= 32)
);
create index analytics_events_name_time_idx on analytics_events (name, occurred_at);
create index analytics_events_user_idx on analytics_events (user_id);

-- Cost monitoring: daily spend, scans and cost per scan, by tier.
create view ai_daily_cost as
select date_trunc('day', created_at) as day,
       tier,
       count(*) filter (where status in ('ok', 'no_food')) as scans,
       count(*) filter (where status = 'cached') as cache_hits,
       count(*) filter (where status in ('error', 'refused')) as failures,
       sum(cost_usd) as cost_usd,
       round(sum(cost_usd) / nullif(count(*) filter (where status in ('ok', 'no_food')), 0), 4) as cost_per_scan
from ai_requests
group by 1, 2;
