-- Cost dashboard views (T2). Read-only; query them from any SQL client.
-- Months and windows are in UTC; "30d" windows are relative to now().
-- Statuses: 'ok' / 'no_food' are completed paid calls, 'cached' is a free
-- cache hit, 'error' / 'refused' are failures, 'pending' is in flight.

-- Spend per calendar month and tier, split by feature.
create view ai_cost_by_month as
select date_trunc('month', created_at at time zone 'UTC')::date as month,
       tier,
       count(*) filter (where status in ('ok', 'no_food', 'error', 'refused')) as calls,
       count(*) filter (where kind = 'meal_scan' and status in ('ok', 'no_food')) as meal_scans,
       count(*) filter (where kind = 'coach_summary' and status = 'ok') as coach_summaries,
       count(*) filter (where status = 'cached') as cache_hits,
       count(*) filter (where status in ('error', 'refused')) as failures,
       coalesce(sum(cost_usd), 0) as cost_usd,
       coalesce(sum(cost_usd) filter (where kind = 'meal_scan'), 0) as meal_scan_cost_usd,
       coalesce(sum(cost_usd) filter (where kind = 'coach_summary'), 0) as coach_summary_cost_usd
from ai_requests
group by 1, 2;

-- AI spend over the last 30 days divided by users active in that window
-- (users.last_seen_at, updated on sign-in and token refresh), per current
-- tier and overall ('all'). Spend is attributed by the tier recorded on each
-- request; active users by their entitlement now. ai_users counts users who
-- made any AI request (including cache hits) in the window.
create view ai_cost_per_active_user_30d as
with active as (
  select u.id,
         case when exists (
           select 1 from subscriptions s
           where s.user_id = u.id and s.revoked_at is null
             and (s.expires_at is null or s.expires_at > now() or s.grace_period_expires_at > now())
         ) then 'pro' else 'free' end as tier
  from users u
  where u.last_seen_at > now() - interval '30 days'
)
select t.tier,
       a.active_users,
       s.ai_users,
       s.cost_usd,
       round(s.cost_usd / nullif(a.active_users, 0), 6) as cost_per_active_user,
       round(s.cost_usd / nullif(s.ai_users, 0), 6) as cost_per_ai_user
from (values ('free'), ('pro'), ('all')) as t(tier)
cross join lateral (
  select count(*) as active_users from active where t.tier in ('all', active.tier)
) a
cross join lateral (
  select count(distinct r.user_id) as ai_users, coalesce(sum(r.cost_usd), 0) as cost_usd
  from ai_requests r
  where r.created_at > now() - interval '30 days' and t.tier in ('all', r.tier)
) s;

-- The 100 most expensive users in the last 30 days. User id only: no Apple
-- identifier or anything else personal. Deleted users (user_id null) are
-- excluded here but still counted in the totals above.
create view ai_top_users_30d as
select user_id,
       count(*) filter (where status in ('ok', 'no_food', 'error', 'refused')) as calls,
       count(*) filter (where kind = 'meal_scan' and status in ('ok', 'no_food')) as meal_scans,
       count(*) filter (where kind = 'coach_summary' and status = 'ok') as coach_summaries,
       sum(cost_usd) as cost_usd
from ai_requests
where user_id is not null and created_at > now() - interval '30 days'
group by user_id
order by cost_usd desc, user_id
limit 100;

-- Meal scan quality over the last 30 days (one row).
--   failure_rate / refusal_rate: errors / refusals over attempts (ok, no_food, refused, error)
--   cache_hit_rate: cache hits over served scans (cached + ok + no_food)
--   corrected_share: stored scans the user corrected, over stored scans
--   mean_abs_calorie_error: mean |logged - estimated| kcal over corrected scans
create view ai_scan_quality_30d as
with requests as (
  select count(*) filter (where status in ('ok', 'no_food', 'refused', 'error')) as attempts,
         count(*) filter (where status in ('ok', 'no_food')) as completed,
         count(*) filter (where status = 'error') as errors,
         count(*) filter (where status = 'refused') as refusals,
         count(*) filter (where status = 'cached') as cache_hits
  from ai_requests
  where kind = 'meal_scan' and created_at > now() - interval '30 days'
), scans as (
  select count(*) as scans,
         count(*) filter (where correction is not null) as corrected,
         avg(abs((correction ->> 'loggedCalories')::numeric - (correction ->> 'estimatedCalories')::numeric)) as mae
  from meal_scans
  where created_at > now() - interval '30 days'
)
select r.attempts,
       r.errors,
       r.refusals,
       r.cache_hits,
       round(r.errors::numeric / nullif(r.attempts, 0), 4) as failure_rate,
       round(r.refusals::numeric / nullif(r.attempts, 0), 4) as refusal_rate,
       round(r.cache_hits::numeric / nullif(r.cache_hits + r.completed, 0), 4) as cache_hit_rate,
       s.scans,
       s.corrected,
       round(s.corrected::numeric / nullif(s.scans, 0), 4) as corrected_share,
       round(s.mae, 1) as mean_abs_calorie_error
from requests r cross join scans s;

-- ai_daily_cost (001) predates coach summaries: keep its columns but count
-- only meal scans as scans, so coach calls don't inflate "cost per scan".
-- cost_usd stays the total for the day and tier.
create or replace view ai_daily_cost as
select date_trunc('day', created_at) as day,
       tier,
       count(*) filter (where kind = 'meal_scan' and status in ('ok', 'no_food')) as scans,
       count(*) filter (where status = 'cached') as cache_hits,
       count(*) filter (where status in ('error', 'refused')) as failures,
       sum(cost_usd) as cost_usd,
       round(sum(cost_usd) filter (where kind = 'meal_scan')
             / nullif(count(*) filter (where kind = 'meal_scan' and status in ('ok', 'no_food')), 0), 4) as cost_per_scan
from ai_requests
group by 1, 2;
