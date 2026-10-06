-- Cost views run with the querying role's privileges (Postgres 15+).
--
-- By default a view runs with its owner's privileges, so any role allowed to
-- select from a view reads ai_requests, users and subscriptions through it
-- even without access to those tables, bypassing their grants and any row
-- level security (on Supabase, the anon / authenticated roles). With
-- security_invoker the caller needs select on the underlying tables as well.
-- Definitions are unchanged (001 / 004); only the option is set, which is
-- equivalent to recreating each view with (security_invoker = true).
alter view ai_daily_cost set (security_invoker = true);
alter view ai_cost_by_month set (security_invoker = true);
alter view ai_cost_per_active_user_30d set (security_invoker = true);
alter view ai_top_users_30d set (security_invoker = true);
alter view ai_scan_quality_30d set (security_invoker = true);

comment on view ai_top_users_30d is
  'Pseudonymous, not anonymous: user_id identifies an account and joins to users (apple_sub). Restrict access like the users table.';

-- Coach summary cache hits are no longer written to ai_requests (one row per
-- screen open was an unbounded write). From here on, the cache_hits columns
-- and cache_hit_rate count meal scan cache hits only; older coach 'cached'
-- rows (zero cost) remain and still count where they fall in a window.
