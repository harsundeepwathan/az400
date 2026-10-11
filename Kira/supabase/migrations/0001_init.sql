-- Kira optional cloud sync schema (NOT deployed; client not implemented — see FeatureFlags.cloudSync).
-- Design: the server stores client-side-encrypted payloads only. Every user-owned table has RLS.

create extension if not exists pgcrypto;

create table public.sync_records (
    id uuid primary key,
    user_id uuid not null references auth.users (id) on delete cascade default auth.uid(),
    record_type text not null check (record_type in ('transaction','account','budget','commitment','income','rule','category')),
    -- AES-GCM ciphertext produced on device; the server cannot read amounts or merchants.
    ciphertext bytea not null check (octet_length(ciphertext) <= 65536),
    nonce bytea not null check (octet_length(nonce) = 12),
    schema_version int not null default 1,
    deleted boolean not null default false,
    updated_at timestamptz not null default now()
);

create index sync_records_user_updated on public.sync_records (user_id, updated_at);

alter table public.sync_records enable row level security;
alter table public.sync_records force row level security;

create policy "own rows: select" on public.sync_records for select to authenticated using (user_id = auth.uid());
create policy "own rows: insert" on public.sync_records for insert to authenticated with check (user_id = auth.uid());
create policy "own rows: update" on public.sync_records for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own rows: delete" on public.sync_records for delete to authenticated using (user_id = auth.uid());

-- No access for anonymous users.
revoke all on public.sync_records from anon;

-- Audit log of sensitive operations (export, delete-account). Insert-only for the owner.
create table public.audit_events (
    id bigint generated always as identity primary key,
    user_id uuid not null references auth.users (id) on delete cascade default auth.uid(),
    action text not null check (char_length(action) <= 64),
    occurred_at timestamptz not null default now()
);
alter table public.audit_events enable row level security;
alter table public.audit_events force row level security;
create policy "own audit: insert" on public.audit_events for insert to authenticated with check (user_id = auth.uid());
create policy "own audit: select" on public.audit_events for select to authenticated using (user_id = auth.uid());
revoke all on public.audit_events from anon;

-- Server-side updated_at so clients cannot backdate rows.
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.user_id := auth.uid();
  return new;
end $$;
create trigger sync_records_touch before insert or update on public.sync_records
for each row execute function public.touch_updated_at();

-- Rate limiting is enforced at the API gateway / Edge Function layer (see docs/SECURITY.md).
