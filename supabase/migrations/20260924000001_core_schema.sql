-- JobPilot core schema.
--
-- Conventions
-- * Every user-owned table carries `user_id` referencing auth.users with
--   ON DELETE CASCADE, so deleting an account removes all of its data.
-- * Child tables reference their parent with a composite (id, user_id) foreign
--   key. Foreign-key checks bypass RLS, so a plain `job_id` FK would let a user
--   attach rows to another user's job id; the composite key makes that
--   impossible at the database level.
-- * Row-level security is enabled on every table; policies only allow the
--   owner (auth.uid()) to see or change a row.
-- * Requires PostgreSQL 15+ (column lists in ON DELETE SET NULL).

create extension if not exists pgcrypto;

create or replace function public.set_updated_at() returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Profile & settings
-- ---------------------------------------------------------------------------

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '' check (char_length(full_name) <= 200),
  current_title text not null default '' check (char_length(current_title) <= 200),
  preferred_locations text[] not null default '{}',
  workplace_preference text not null default 'flexible'
    check (workplace_preference in ('remote', 'hybrid', 'onsite', 'flexible')),
  target_salary integer check (target_salary is null or target_salary >= 0),
  salary_currency text not null default 'USD' check (salary_currency ~ '^[A-Z]{3}$'),
  employment_types text[] not null default '{full_time}',
  willing_to_relocate boolean not null default false,
  work_authorization_notes text not null default '' check (char_length(work_authorization_notes) <= 2000),
  search_started_on date,
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  weekly_application_goal integer not null default 5 check (weekly_application_goal between 0 and 100),
  follow_up_after_days integer not null default 7 check (follow_up_after_days between 1 and 60),
  ai_assistance_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.target_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index target_roles_user_idx on public.target_roles (user_id, position);

-- ---------------------------------------------------------------------------
-- Resumes & career profile
-- ---------------------------------------------------------------------------

create table public.resumes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  source_type text not null check (source_type in ('upload', 'paste')),
  original_filename text,
  storage_path text,
  mime_type text,
  file_size integer check (file_size is null or file_size >= 0),
  raw_text text not null default '',
  parse_status text not null default 'manual'
    check (parse_status in ('parsed', 'partial', 'unreadable', 'manual')),
  parse_warnings jsonb not null default '[]'::jsonb,
  contact jsonb not null default '{}'::jsonb,
  summary text not null default '',
  languages text[] not null default '{}',
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id)
);
create index resumes_user_idx on public.resumes (user_id, created_at desc);
create unique index resumes_one_primary_idx on public.resumes (user_id) where is_primary;

create table public.employment_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  resume_id uuid not null,
  employer text not null default '',
  title text not null default '',
  location text not null default '',
  start_date text not null default '' check (start_date = '' or start_date ~ '^\d{4}(-\d{2})?$'),
  end_date text not null default '' check (end_date = '' or end_date ~ '^\d{4}(-\d{2})?$'),
  is_current boolean not null default false,
  responsibilities text[] not null default '{}',
  achievements text[] not null default '{}',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (resume_id, user_id) references public.resumes (id, user_id) on delete cascade
);
create index employment_entries_resume_idx on public.employment_entries (resume_id, position);
create index employment_entries_user_idx on public.employment_entries (user_id);

create table public.education_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  resume_id uuid not null,
  institution text not null default '',
  qualification text not null default '',
  field_of_study text not null default '',
  start_date text not null default '',
  end_date text not null default '',
  notes text not null default '',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (resume_id, user_id) references public.resumes (id, user_id) on delete cascade
);
create index education_entries_resume_idx on public.education_entries (resume_id, position);
create index education_entries_user_idx on public.education_entries (user_id);

create table public.certifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  resume_id uuid not null,
  name text not null check (char_length(name) between 1 and 300),
  issuer text not null default '',
  issued_on text not null default '',
  expires_on text not null default '',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (resume_id, user_id) references public.resumes (id, user_id) on delete cascade
);
create index certifications_resume_idx on public.certifications (resume_id, position);
create index certifications_user_idx on public.certifications (user_id);

create table public.skills (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  resume_id uuid not null,
  name text not null check (char_length(name) between 1 and 100),
  category text not null default '',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (resume_id, user_id) references public.resumes (id, user_id) on delete cascade
);
create unique index skills_resume_name_idx on public.skills (resume_id, lower(name));
create index skills_user_idx on public.skills (user_id);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  resume_id uuid not null,
  name text not null check (char_length(name) between 1 and 300),
  description text not null default '',
  skills text[] not null default '{}',
  url text not null default '',
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (resume_id, user_id) references public.resumes (id, user_id) on delete cascade
);
create index projects_resume_idx on public.projects (resume_id, position);
create index projects_user_idx on public.projects (user_id);

create table public.evidence_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 300),
  organization text not null default '',
  situation text not null default '',
  action text not null default '',
  result text not null default '',
  skills text[] not null default '{}',
  metric text not null default '',
  source text not null default 'user_entered'
    check (source in ('resume', 'user_entered', 'interview_reflection')),
  source_employment_id uuid,
  confidence text not null default 'medium' check (confidence in ('high', 'medium', 'low')),
  verification_status text not null default 'unverified'
    check (verification_status in ('verified', 'unverified', 'rejected')),
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (source_employment_id, user_id)
    references public.employment_entries (id, user_id) on delete set null (source_employment_id)
);
create index evidence_items_user_idx on public.evidence_items (user_id, updated_at desc);

create table public.resume_versions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  resume_id uuid not null,
  job_id uuid,
  name text not null check (char_length(name) between 1 and 200),
  summary text not null default '',
  -- Structured document: { employment: [{ employment_id, bullets: [] }], skills: [] }
  content jsonb not null default '{}'::jsonb,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (resume_id, user_id) references public.resumes (id, user_id) on delete cascade
);
create index resume_versions_user_idx on public.resume_versions (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Jobs & fit analysis
-- ---------------------------------------------------------------------------

create table public.jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 300),
  company text not null check (char_length(company) between 1 and 300),
  url text not null default '',
  location text not null default '',
  workplace_type text not null default 'unknown'
    check (workplace_type in ('remote', 'hybrid', 'onsite', 'unknown')),
  salary_min integer check (salary_min is null or salary_min >= 0),
  salary_max integer check (salary_max is null or salary_max >= 0),
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  description text not null default '' check (char_length(description) <= 60000),
  source text not null default '',
  discovered_on date not null default current_date,
  closes_on date,
  contact_name text not null default '',
  contact_email text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  check (salary_min is null or salary_max is null or salary_min <= salary_max)
);
create index jobs_user_idx on public.jobs (user_id, created_at desc);

alter table public.resume_versions
  add foreign key (job_id, user_id) references public.jobs (id, user_id) on delete set null (job_id);

create table public.job_requirements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  job_id uuid not null,
  text text not null check (char_length(text) between 1 and 1000),
  kind text not null check (kind in ('must', 'nice')),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (job_id, user_id) references public.jobs (id, user_id) on delete cascade
);
create index job_requirements_job_idx on public.job_requirements (job_id, position);

create table public.fit_analyses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  job_id uuid not null,
  resume_id uuid,
  provider text not null,
  model text not null default '',
  prompt_version text not null,
  score integer not null check (score between 0 and 100),
  recommendation text not null
    check (recommendation in ('strong_apply', 'apply', 'stretch', 'low_value')),
  explanation text not null default '',
  seniority_alignment jsonb not null default '{}'::jsonb,
  location_considerations jsonb not null default '[]'::jsonb,
  emphasize jsonb not null default '[]'::jsonb,
  questions jsonb not null default '[]'::jsonb,
  coverage jsonb not null default '{}'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (job_id, user_id) references public.jobs (id, user_id) on delete cascade,
  foreign key (resume_id, user_id) references public.resumes (id, user_id) on delete set null (resume_id)
);
create index fit_analyses_job_idx on public.fit_analyses (job_id, created_at desc);
create index fit_analyses_user_idx on public.fit_analyses (user_id, created_at desc);

create table public.fit_matches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  analysis_id uuid not null,
  requirement_text text not null,
  requirement_kind text not null check (requirement_kind in ('must', 'nice')),
  match_type text not null check (match_type in ('strong', 'transferable', 'unclear', 'missing')),
  explanation text not null default '',
  -- Snapshot of the cited source so the analysis stays readable if the
  -- underlying resume field is later edited or deleted.
  source_type text check (source_type in
    ('skill', 'employment', 'certification', 'education', 'project', 'evidence', 'summary')),
  source_id uuid,
  source_label text not null default '',
  needs_confirmation boolean not null default false,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (analysis_id, user_id) references public.fit_analyses (id, user_id) on delete cascade
);
create index fit_matches_analysis_idx on public.fit_matches (analysis_id, position);

-- ---------------------------------------------------------------------------
-- Applications & tracking
-- ---------------------------------------------------------------------------

create table public.applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  job_id uuid not null,
  resume_version_id uuid,
  stage text not null default 'interested' check (stage in (
    'interested', 'preparing', 'applied', 'recruiter_screen', 'interview', 'final_interview',
    'background_checks', 'offer', 'rejected', 'withdrawn', 'archived')),
  stage_changed_at timestamptz not null default now(),
  applied_on date,
  next_action text not null default '',
  next_action_on date,
  follow_up_on date,
  salary_expectation text not null default '',
  rejection_reason text not null default '',
  offer_details text not null default '',
  offer_deadline date,
  notes text not null default '',
  checklist jsonb not null default '[]'::jsonb,
  selected_evidence_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  unique (job_id),
  foreign key (job_id, user_id) references public.jobs (id, user_id) on delete cascade,
  foreign key (resume_version_id, user_id)
    references public.resume_versions (id, user_id) on delete set null (resume_version_id)
);
create index applications_user_stage_idx on public.applications (user_id, stage);

-- Immutable log of stage transitions; analytics are computed from this table.
create table public.application_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  application_id uuid not null,
  from_stage text,
  to_stage text not null,
  occurred_at timestamptz not null default now(),
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (application_id, user_id) references public.applications (id, user_id) on delete cascade
);
create index application_events_app_idx on public.application_events (application_id, occurred_at);
create index application_events_user_idx on public.application_events (user_id, occurred_at);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  application_id uuid not null,
  name text not null check (char_length(name) between 1 and 200),
  role text not null default 'recruiter'
    check (role in ('recruiter', 'hiring_manager', 'interviewer', 'referral', 'other')),
  email text not null default '',
  phone text not null default '',
  profile_url text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (application_id, user_id) references public.applications (id, user_id) on delete cascade
);
create index contacts_application_idx on public.contacts (application_id);

create table public.interviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  application_id uuid not null,
  scheduled_at timestamptz not null,
  kind text not null default 'other' check (kind in
    ('recruiter_screen', 'technical', 'behavioural', 'panel', 'final', 'other')),
  interviewers text not null default '',
  location text not null default '',
  notes text not null default '',
  reflection text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (application_id, user_id) references public.applications (id, user_id) on delete cascade
);
create index interviews_user_idx on public.interviews (user_id, scheduled_at);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  application_id uuid,
  interview_id uuid,
  kind text not null default 'custom' check (kind in
    ('follow_up', 'interview_prep', 'application_deadline', 'recruiter_response', 'offer_deadline', 'custom')),
  title text not null check (char_length(title) between 1 and 300),
  due_on date not null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (application_id, user_id) references public.applications (id, user_id) on delete cascade,
  foreign key (interview_id, user_id) references public.interviews (id, user_id) on delete cascade
);
create index tasks_user_due_idx on public.tasks (user_id, due_on) where completed_at is null;

create table public.generated_documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  application_id uuid not null,
  kind text not null check (kind in ('application_materials', 'interview_prep')),
  content jsonb not null,
  warnings jsonb not null default '[]'::jsonb,
  provider text not null,
  model text not null default '',
  prompt_version text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (application_id, user_id) references public.applications (id, user_id) on delete cascade
);
create index generated_documents_app_idx on public.generated_documents (application_id, kind, created_at desc);

-- Metadata only (no prompt or response content) used for per-user rate limiting.
create table public.ai_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  operation text not null,
  created_at timestamptz not null default now()
);
create index ai_requests_user_idx on public.ai_requests (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- updated_at triggers, RLS and grants
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
  owned_tables text[] := array[
    'profiles', 'user_settings', 'target_roles', 'resumes', 'employment_entries',
    'education_entries', 'certifications', 'skills', 'projects', 'evidence_items',
    'resume_versions', 'jobs', 'job_requirements', 'fit_analyses', 'fit_matches',
    'applications', 'application_events', 'contacts', 'interviews', 'tasks',
    'generated_documents', 'ai_requests'
  ];
begin
  foreach t in array owned_tables loop
    if t <> 'ai_requests' then
      execute format(
        'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
        t || '_updated_at', t);
    end if;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))',
      t || '_owner', t);
  end loop;
end
$$;

-- Application events are an append-only audit trail for analytics.
revoke update on public.application_events from authenticated;
