-- Claude-written weekly coach summary (T3).

alter table ai_requests drop constraint ai_requests_kind_check;
alter table ai_requests add constraint ai_requests_kind_check check (kind in ('meal_scan', 'coach_summary'));

-- At most one generated summary per user per UTC day. Only the summary text is
-- kept, never the digest it was written from.
create table coach_summaries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  day date not null,
  summary text not null check (length(summary) between 1 and 600),
  request_id uuid references ai_requests(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (user_id, day)
);
