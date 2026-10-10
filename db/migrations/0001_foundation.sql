-- Skywatch foundation schema.
-- Conventions:
--   * Every tenant-owned table carries org_id and has row-level security enabled.
--   * The API connects as skywatch_api (subject to RLS) and sets app.org_id / app.user_id
--     per transaction. Workers connect as skywatch_worker (BYPASSRLS) and always filter
--     by org_id explicitly.
--   * Enumerations are text + CHECK constraints so they can evolve without type rewrites.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Helper: current tenant / user from the transaction-local settings.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_org_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.org_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION app_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

-- ---------------------------------------------------------------------------
-- Identity & tenancy
-- ---------------------------------------------------------------------------
CREATE TABLE organizations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  slug        text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  is_demo     boolean NOT NULL DEFAULT false,
  settings    jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email          text NOT NULL,
  display_name   text NOT NULL,
  -- Only used by the local-development identity provider. Production uses OIDC.
  password_hash  text,
  oidc_issuer    text,
  oidc_subject   text,
  disabled       boolean NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now(),
  last_login_at  timestamptz,
  UNIQUE (oidc_issuer, oidc_subject)
);
CREATE UNIQUE INDEX users_email_lower ON users (lower(email));

CREATE TABLE memberships (
  org_id     uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('org_admin','infra_admin','operator','viewer')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, user_id)
);
CREATE INDEX memberships_user ON memberships(user_id);

-- Server-side sessions. The cookie carries a random token; only its SHA-256 is stored.
CREATE TABLE sessions (
  token_hash    bytea PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  org_id        uuid REFERENCES organizations(id) ON DELETE SET NULL,
  csrf_token    text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  ip            inet,
  user_agent    text
);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE INDEX sessions_expiry ON sessions(expires_at);

CREATE TABLE audit_logs (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id         uuid REFERENCES organizations(id) ON DELETE CASCADE,
  actor_type     text NOT NULL CHECK (actor_type IN ('user','agent','system')),
  actor_id       text,
  actor_label    text,
  action         text NOT NULL,
  target_type    text,
  target_id      text,
  details        jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip             inet,
  at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_org_at ON audit_logs(org_id, at DESC);

-- ---------------------------------------------------------------------------
-- Cloud accounts & inventory
-- ---------------------------------------------------------------------------
CREATE TABLE cloud_accounts (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  provider               text NOT NULL CHECK (provider IN ('azure','alibaba','digitalocean','aws','gcp','vmware','onprem','demo')),
  name                   text NOT NULL,
  -- Subscription ID (Azure), account UID (Alibaba), team UUID / label (DigitalOcean).
  external_id            text,
  auth_method            text NOT NULL,
  -- AES-256-GCM envelope-encrypted credential document. Never returned by the API.
  credential_ciphertext  bytea,
  credential_key_id      text,
  credential_hint        text,     -- non-secret hint, e.g. client id or last 4 chars
  config                 jsonb NOT NULL DEFAULT '{}'::jsonb,
  status                 text NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending','validating','active','degraded','error','disabled')),
  status_reason          text,
  capabilities           jsonb NOT NULL DEFAULT '{}'::jsonb,
  permission_report      jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_validated_at      timestamptz,
  last_discovery_at      timestamptz,
  last_success_at        timestamptz,
  throttle_events        bigint NOT NULL DEFAULT 0,
  last_throttled_at      timestamptz,
  created_by             uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cloud_accounts_org ON cloud_accounts(org_id);

CREATE TABLE resources (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  cloud_account_id       uuid REFERENCES cloud_accounts(id) ON DELETE CASCADE,
  provider               text NOT NULL,
  provider_resource_id   text NOT NULL,
  external_account_id    text,          -- subscription / account / project identifier
  name                   text NOT NULL,
  resource_type          text NOT NULL, -- normalized type, see docs/STATE_MODEL.md
  native_type            text,          -- provider type, e.g. microsoft.compute/virtualmachines
  region                 text,
  resource_group         text,
  environment            text,
  os_type                text CHECK (os_type IS NULL OR os_type IN ('windows','linux','other')),
  os_name                text,
  config                 jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Provider-reported state (raw and normalized). This is NOT workload health.
  provider_state_raw     text,
  power_state            text NOT NULL DEFAULT 'unknown'
                           CHECK (power_state IN ('running','stopped','deallocated','starting','stopping','provisioning','deleting','unknown','not_applicable')),
  provider_health        text NOT NULL DEFAULT 'unknown'
                           CHECK (provider_health IN ('available','degraded','unavailable','unknown')),
  provider_health_reason text,
  -- Observed operational state computed by the evaluator from all signals.
  operational_state      text NOT NULL DEFAULT 'no_data'
                           CHECK (operational_state IN ('healthy','warning','critical','down','stopped','unknown','maintenance','no_data')),
  state_reason           text,
  state_since            timestamptz NOT NULL DEFAULT now(),
  signals                jsonb NOT NULL DEFAULT '{}'::jsonb,
  monitoring_enabled     boolean NOT NULL DEFAULT true,
  discovered_at          timestamptz NOT NULL DEFAULT now(),
  last_seen_in_discovery timestamptz,
  last_telemetry_at      timestamptz,
  deleted_at             timestamptz,
  UNIQUE (org_id, provider, provider_resource_id)
);
CREATE INDEX resources_org_state ON resources(org_id, operational_state) WHERE deleted_at IS NULL;
CREATE INDEX resources_org_type ON resources(org_id, resource_type) WHERE deleted_at IS NULL;
CREATE INDEX resources_account ON resources(cloud_account_id);

CREATE TABLE resource_tags (
  org_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  resource_id  uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  key          text NOT NULL,
  value        text NOT NULL DEFAULT '',
  PRIMARY KEY (resource_id, key)
);
CREATE INDEX resource_tags_org_kv ON resource_tags(org_id, key, value);

-- Infrastructure relationships used for incident correlation (never for asserted root cause).
CREATE TABLE resource_relations (
  org_id            uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  from_resource_id  uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  to_resource_id    uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN ('depends_on','member_of','backend_of','attached_to')),
  source            text NOT NULL DEFAULT 'discovery',
  PRIMARY KEY (from_resource_id, to_resource_id, kind)
);

-- Interval history of operational state, used for availability calculations.
CREATE TABLE resource_state_history (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  resource_id  uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  state        text NOT NULL,
  reason       text,
  started_at   timestamptz NOT NULL,
  ended_at     timestamptz
);
CREATE INDEX resource_state_history_res ON resource_state_history(resource_id, started_at DESC);
CREATE UNIQUE INDEX resource_state_history_open ON resource_state_history(resource_id) WHERE ended_at IS NULL;

-- ---------------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------------
CREATE TABLE agent_enrollment_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  token_hash   bytea NOT NULL UNIQUE,
  token_prefix text NOT NULL,
  description  text NOT NULL DEFAULT '',
  max_uses     integer NOT NULL DEFAULT 1 CHECK (max_uses > 0),
  uses         integer NOT NULL DEFAULT 0,
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  created_by   uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agents (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  resource_id            uuid REFERENCES resources(id) ON DELETE SET NULL,
  enrollment_token_id    uuid REFERENCES agent_enrollment_tokens(id) ON DELETE SET NULL,
  hostname               text NOT NULL,
  os_type                text NOT NULL,
  os_name                text,
  os_version             text,
  kernel_version         text,
  arch                   text,
  agent_version          text NOT NULL,
  secret_hash            bytea NOT NULL,
  prev_secret_hash       bytea,
  prev_secret_expires_at timestamptz,
  secret_rotated_at      timestamptz NOT NULL DEFAULT now(),
  cloud_metadata         jsonb NOT NULL DEFAULT '{}'::jsonb,
  config                 jsonb NOT NULL DEFAULT '{}'::jsonb,
  status                 text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
  enrolled_at            timestamptz NOT NULL DEFAULT now(),
  last_heartbeat_at      timestamptz,
  last_heartbeat_latency_ms integer,
  last_boot_at           timestamptz,
  last_seq               bigint NOT NULL DEFAULT 0,
  last_queue_depth       integer,
  last_dropped_batches   bigint
);
CREATE INDEX agents_org ON agents(org_id);
CREATE INDEX agents_resource ON agents(resource_id);

-- ---------------------------------------------------------------------------
-- Telemetry
-- ---------------------------------------------------------------------------
CREATE TABLE metric_definitions (
  key          text PRIMARY KEY,
  unit         text NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('gauge','rate','counter')),
  category     text NOT NULL,
  description  text NOT NULL
);

-- Raw measurements. Partitioned daily; partitions are created ahead of time and dropped
-- once they fall outside the raw retention window (default 30 days).
CREATE TABLE metric_samples (
  org_id       uuid NOT NULL,
  resource_id  uuid NOT NULL,
  metric       text NOT NULL,
  series       text NOT NULL DEFAULT '',
  ts           timestamptz NOT NULL,
  value        double precision NOT NULL,
  source       text NOT NULL
) PARTITION BY RANGE (ts);
CREATE INDEX metric_samples_lookup ON metric_samples(resource_id, metric, ts DESC);
CREATE INDEX metric_samples_org_ts ON metric_samples(org_id, ts);

-- Aggregated measurements (1h buckets), kept for 12 months by default.
CREATE TABLE metric_rollups_1h (
  org_id       uuid NOT NULL,
  resource_id  uuid NOT NULL,
  metric       text NOT NULL,
  series       text NOT NULL DEFAULT '',
  bucket       timestamptz NOT NULL,
  avg          double precision NOT NULL,
  min          double precision NOT NULL,
  max          double precision NOT NULL,
  count        integer NOT NULL,
  PRIMARY KEY (resource_id, metric, series, bucket)
);
CREATE INDEX metric_rollups_1h_org ON metric_rollups_1h(org_id, bucket);

-- Latest value per series for fast inventory rendering.
CREATE TABLE metric_latest (
  org_id       uuid NOT NULL,
  resource_id  uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  metric       text NOT NULL,
  series       text NOT NULL DEFAULT '',
  ts           timestamptz NOT NULL,
  value        double precision NOT NULL,
  source       text NOT NULL,
  PRIMARY KEY (resource_id, metric, series)
);
CREATE INDEX metric_latest_org_metric ON metric_latest(org_id, metric);

CREATE TABLE heartbeats (
  org_id       uuid NOT NULL,
  agent_id     uuid NOT NULL,
  resource_id  uuid,
  sent_at      timestamptz NOT NULL,
  received_at  timestamptz NOT NULL,
  latency_ms   integer,
  seq          bigint NOT NULL
) PARTITION BY RANGE (received_at);
CREATE INDEX heartbeats_agent ON heartbeats(agent_id, received_at DESC);

-- Monitored OS services (Windows Services / systemd units).
CREATE TABLE service_checks (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  resource_id      uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  agent_id         uuid REFERENCES agents(id) ON DELETE SET NULL,
  platform         text NOT NULL CHECK (platform IN ('windows','systemd','process')),
  name             text NOT NULL,
  display_name     text,
  -- What the operator says should be true. 'running' means alert when not running.
  -- 'any' means informational only (default for discovered services).
  expected_state   text NOT NULL DEFAULT 'any' CHECK (expected_state IN ('running','stopped','any')),
  critical         boolean NOT NULL DEFAULT false,
  startup_type     text,
  current_state    text,
  sub_state        text,
  pid              integer,
  restart_count    integer,
  last_change_at   timestamptz,
  last_reported_at timestamptz,
  discovered       boolean NOT NULL DEFAULT false,
  UNIQUE (resource_id, platform, name)
);
CREATE INDEX service_checks_org ON service_checks(org_id);

CREATE TABLE service_events (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  service_id   uuid NOT NULL REFERENCES service_checks(id) ON DELETE CASCADE,
  resource_id  uuid NOT NULL REFERENCES resources(id) ON DELETE CASCADE,
  from_state   text,
  to_state     text NOT NULL,
  at           timestamptz NOT NULL,
  details      jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX service_events_res ON service_events(resource_id, at DESC);

-- Infrastructure / OS events (Azure Activity Log entries, Windows Event Log, journal).
CREATE TABLE infra_events (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  resource_id  uuid REFERENCES resources(id) ON DELETE CASCADE,
  source       text NOT NULL,
  kind         text NOT NULL,
  severity     text NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','error','critical')),
  message      text NOT NULL,
  at           timestamptz NOT NULL,
  external_id  text,
  details      jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE (org_id, source, external_id)
);
CREATE INDEX infra_events_res ON infra_events(resource_id, at DESC);
CREATE INDEX infra_events_org ON infra_events(org_id, at DESC);

-- ---------------------------------------------------------------------------
-- Synthetic monitoring
-- ---------------------------------------------------------------------------
CREATE TABLE synthetic_checks (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id               uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  resource_id          uuid REFERENCES resources(id) ON DELETE SET NULL,
  name                 text NOT NULL,
  kind                 text NOT NULL CHECK (kind IN ('http','tcp','dns','tls')),
  target               text NOT NULL,
  config               jsonb NOT NULL DEFAULT '{}'::jsonb,
  interval_seconds     integer NOT NULL DEFAULT 60 CHECK (interval_seconds BETWEEN 30 AND 86400),
  probe_scope          text NOT NULL DEFAULT 'public' CHECK (probe_scope IN ('public','private')),
  locations            text[] NOT NULL DEFAULT ARRAY['default'],
  enabled              boolean NOT NULL DEFAULT true,
  next_run_at          timestamptz NOT NULL DEFAULT now(),
  lease_until          timestamptz,
  last_run_at          timestamptz,
  last_ok              boolean,
  last_latency_ms      integer,
  last_error           text,
  consecutive_failures integer NOT NULL DEFAULT 0,
  created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX synthetic_checks_due ON synthetic_checks(next_run_at) WHERE enabled;

CREATE TABLE synthetic_results (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  check_id     uuid NOT NULL REFERENCES synthetic_checks(id) ON DELETE CASCADE,
  location     text NOT NULL,
  at           timestamptz NOT NULL,
  ok           boolean NOT NULL,
  latency_ms   integer,
  status_code  integer,
  error        text,
  details      jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX synthetic_results_check ON synthetic_results(check_id, at DESC);

-- ---------------------------------------------------------------------------
-- Policies, alerting & incidents
-- ---------------------------------------------------------------------------
CREATE TABLE monitoring_policies (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name                     text NOT NULL,
  is_default               boolean NOT NULL DEFAULT false,
  priority                 integer NOT NULL DEFAULT 100,
  scope                    jsonb NOT NULL DEFAULT '{}'::jsonb,
  heartbeat_interval_s     integer NOT NULL DEFAULT 60 CHECK (heartbeat_interval_s BETWEEN 10 AND 3600),
  heartbeat_warning_s      integer NOT NULL DEFAULT 120,
  heartbeat_critical_s     integer NOT NULL DEFAULT 300,
  metrics_interval_s       integer NOT NULL DEFAULT 60,
  flap_window_s            integer NOT NULL DEFAULT 900,
  flap_threshold           integer NOT NULL DEFAULT 4,
  CHECK (heartbeat_warning_s < heartbeat_critical_s)
);
CREATE UNIQUE INDEX monitoring_policies_default ON monitoring_policies(org_id) WHERE is_default;

CREATE TABLE escalation_policies (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name                text NOT NULL,
  -- [{"delay_seconds":0,"channel_ids":["..."]}, {"delay_seconds":900,...}]
  steps               jsonb NOT NULL DEFAULT '[]'::jsonb,
  repeat_interval_s   integer CHECK (repeat_interval_s IS NULL OR repeat_interval_s >= 300),
  notify_on_resolve   boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE alert_rules (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name                text NOT NULL,
  description         text NOT NULL DEFAULT '',
  enabled             boolean NOT NULL DEFAULT true,
  kind                text NOT NULL CHECK (kind IN ('metric_threshold','heartbeat','service_state','synthetic','provider_state')),
  metric              text,
  series_match        text,                 -- glob on the series key, e.g. 'mount=*'
  aggregation         text NOT NULL DEFAULT 'avg' CHECK (aggregation IN ('avg','min','max','last')),
  operator            text CHECK (operator IN ('>','>=','<','<=')),
  threshold           double precision,
  recovery_threshold  double precision,     -- hysteresis; defaults to threshold
  for_seconds         integer NOT NULL DEFAULT 300 CHECK (for_seconds >= 0),
  consecutive         integer NOT NULL DEFAULT 1 CHECK (consecutive >= 1),
  severity            text NOT NULL CHECK (severity IN ('warning','critical')),
  scope               jsonb NOT NULL DEFAULT '{}'::jsonb,
  exclusions          jsonb NOT NULL DEFAULT '{}'::jsonb,
  escalation_policy_id uuid REFERENCES escalation_policies(id) ON DELETE SET NULL,
  created_by          uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX alert_rules_org ON alert_rules(org_id) WHERE enabled;

CREATE TABLE incidents (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  number                bigint GENERATED ALWAYS AS IDENTITY,
  title                 text NOT NULL,
  severity              text NOT NULL CHECK (severity IN ('warning','critical')),
  status                text NOT NULL DEFAULT 'open' CHECK (status IN ('open','acknowledged','resolved')),
  resource_id           uuid REFERENCES resources(id) ON DELETE SET NULL,
  cloud_account_id      uuid REFERENCES cloud_accounts(id) ON DELETE SET NULL,
  parent_incident_id    uuid REFERENCES incidents(id) ON DELETE SET NULL,
  dedup_key             text NOT NULL,
  correlation_note      text,
  trigger_summary       text NOT NULL,
  first_detected_at     timestamptz NOT NULL,
  last_observed_at      timestamptz NOT NULL,
  acknowledged_at       timestamptz,
  acknowledged_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  assigned_to           uuid REFERENCES users(id) ON DELETE SET NULL,
  resolved_at           timestamptz,
  resolution            text CHECK (resolution IS NULL OR resolution IN ('auto','manual')),
  escalation_policy_id  uuid REFERENCES escalation_policies(id) ON DELETE SET NULL,
  escalation_step       integer NOT NULL DEFAULT 0,
  next_escalation_at    timestamptz,
  last_notified_at      timestamptz
);
-- At most one non-resolved incident per dedup key: this is the deduplication guarantee.
CREATE UNIQUE INDEX incidents_open_dedup ON incidents(org_id, dedup_key) WHERE status <> 'resolved';
CREATE INDEX incidents_org_status ON incidents(org_id, status, first_detected_at DESC);
CREATE INDEX incidents_resource ON incidents(resource_id, first_detected_at DESC);

CREATE TABLE alert_instances (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  rule_id               uuid NOT NULL REFERENCES alert_rules(id) ON DELETE CASCADE,
  resource_id           uuid REFERENCES resources(id) ON DELETE CASCADE,
  subject_id            text NOT NULL,        -- resource id, check id or service id
  series                text NOT NULL DEFAULT '',
  state                 text NOT NULL CHECK (state IN ('normal','pending','firing','resolved')),
  value                 double precision,
  summary               text,
  pending_since         timestamptz,
  firing_since          timestamptz,
  resolved_at           timestamptz,
  last_eval_at          timestamptz NOT NULL,
  breaches              integer NOT NULL DEFAULT 0,
  suppressed_reason     text,
  incident_id           uuid REFERENCES incidents(id) ON DELETE SET NULL,
  UNIQUE (rule_id, subject_id, series)
);
CREATE INDEX alert_instances_org_state ON alert_instances(org_id, state);

CREATE TABLE alert_events (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id             uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  alert_instance_id  uuid NOT NULL REFERENCES alert_instances(id) ON DELETE CASCADE,
  rule_id            uuid NOT NULL,
  resource_id        uuid,
  from_state         text NOT NULL,
  to_state           text NOT NULL,
  value              double precision,
  message            text,
  at                 timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX alert_events_instance ON alert_events(alert_instance_id, at DESC);

CREATE TABLE incident_events (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id        uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  incident_id   uuid NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  at            timestamptz NOT NULL DEFAULT now(),
  kind          text NOT NULL,
  actor_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  message       text NOT NULL,
  data          jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX incident_events_incident ON incident_events(incident_id, at);

CREATE TABLE notification_channels (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id             uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  kind               text NOT NULL CHECK (kind IN ('email','slack','teams','webhook','telegram')),
  name               text NOT NULL,
  -- Secret parts (webhook URLs, bot tokens, HMAC secrets), envelope-encrypted.
  secret_ciphertext  bytea,
  secret_key_id      text,
  config             jsonb NOT NULL DEFAULT '{}'::jsonb,
  enabled            boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE notification_deliveries (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id           uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  incident_id      uuid REFERENCES incidents(id) ON DELETE CASCADE,
  channel_id       uuid NOT NULL REFERENCES notification_channels(id) ON DELETE CASCADE,
  event            text NOT NULL,
  dedup_key        text NOT NULL UNIQUE,
  payload          jsonb NOT NULL,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed')),
  attempts         integer NOT NULL DEFAULT 0,
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  last_error       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  sent_at          timestamptz
);
CREATE INDEX notification_deliveries_due ON notification_deliveries(next_attempt_at) WHERE status = 'pending';

CREATE TABLE maintenance_windows (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name            text NOT NULL,
  starts_at       timestamptz NOT NULL,
  ends_at         timestamptz NOT NULL,
  scope           jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);
CREATE INDEX maintenance_windows_active ON maintenance_windows(org_id, starts_at, ends_at);

-- ---------------------------------------------------------------------------
-- Platform self-monitoring & durable scheduling
-- ---------------------------------------------------------------------------
CREATE TABLE collection_jobs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  cloud_account_id      uuid NOT NULL REFERENCES cloud_accounts(id) ON DELETE CASCADE,
  kind                  text NOT NULL CHECK (kind IN ('discovery','metrics','health','heartbeat')),
  interval_seconds      integer NOT NULL CHECK (interval_seconds >= 30),
  next_run_at           timestamptz NOT NULL DEFAULT now(),
  lease_owner           text,
  lease_expires_at      timestamptz,
  last_started_at       timestamptz,
  last_finished_at      timestamptz,
  last_status           text CHECK (last_status IS NULL OR last_status IN ('ok','partial','error','throttled','skipped')),
  last_error            text,
  last_duration_ms      integer,
  consecutive_failures  integer NOT NULL DEFAULT 0,
  UNIQUE (cloud_account_id, kind)
);
CREATE INDEX collection_jobs_due ON collection_jobs(next_run_at);

CREATE TABLE collector_runs (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  org_id            uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  job_id            uuid NOT NULL REFERENCES collection_jobs(id) ON DELETE CASCADE,
  cloud_account_id  uuid NOT NULL,
  kind              text NOT NULL,
  instance_id       text NOT NULL,
  started_at        timestamptz NOT NULL,
  finished_at       timestamptz NOT NULL,
  status            text NOT NULL,
  error             text,
  api_calls         integer NOT NULL DEFAULT 0,
  throttled_calls   integer NOT NULL DEFAULT 0,
  items             integer NOT NULL DEFAULT 0
);
CREATE INDEX collector_runs_job ON collector_runs(job_id, started_at DESC);
CREATE INDEX collector_runs_org ON collector_runs(org_id, started_at DESC);

CREATE TABLE platform_instances (
  instance_id     text PRIMARY KEY,
  roles           text[] NOT NULL,
  version         text NOT NULL,
  hostname        text NOT NULL,
  started_at      timestamptz NOT NULL,
  last_heartbeat  timestamptz NOT NULL,
  stats           jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'cloud_accounts','resources','resource_tags','resource_relations','resource_state_history',
    'agent_enrollment_tokens','agents','metric_samples','metric_rollups_1h','metric_latest',
    'heartbeats','service_checks','service_events','infra_events','synthetic_checks',
    'synthetic_results','monitoring_policies','escalation_policies','alert_rules','incidents',
    'alert_instances','alert_events','incident_events','notification_channels',
    'notification_deliveries','maintenance_windows','collection_jobs','collector_runs','audit_logs'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (org_id = app_org_id()) WITH CHECK (org_id = app_org_id())', t);
  END LOOP;
END $$;

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations FORCE ROW LEVEL SECURITY;
-- A user can see the organizations they belong to; the active org is always visible.
CREATE POLICY org_visibility ON organizations
  USING (id = app_org_id() OR id IN (SELECT org_id FROM memberships WHERE user_id = app_user_id()));

ALTER TABLE memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships FORCE ROW LEVEL SECURITY;
CREATE POLICY membership_visibility ON memberships
  USING (org_id = app_org_id() OR user_id = app_user_id())
  WITH CHECK (org_id = app_org_id());

-- ---------------------------------------------------------------------------
-- Partition management helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION skywatch_ensure_daily_partitions(parent regclass, days_ahead int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE d date; part text;
BEGIN
  FOR i IN -1..days_ahead LOOP
    d := (now() AT TIME ZONE 'UTC')::date + i;
    part := format('%s_p%s', parent::text, to_char(d, 'YYYYMMDD'));
    IF to_regclass(part) IS NULL THEN
      EXECUTE format('CREATE TABLE %I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
                     part, parent, d::timestamp AT TIME ZONE 'UTC', (d + 1)::timestamp AT TIME ZONE 'UTC');
    END IF;
  END LOOP;
END $$;

-- Drops whole daily partitions older than the retention window. Returns dropped names.
CREATE OR REPLACE FUNCTION skywatch_drop_old_partitions(parent regclass, keep_days int)
RETURNS SETOF text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; cutoff date := (now() AT TIME ZONE 'UTC')::date - keep_days;
BEGIN
  FOR r IN
    SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = parent
  LOOP
    IF r.relname ~ '_p[0-9]{8}$' AND to_date(right(r.relname, 8), 'YYYYMMDD') < cutoff THEN
      EXECUTE format('DROP TABLE %I', r.relname);
      RETURN NEXT r.relname;
    END IF;
  END LOOP;
END $$;

SELECT skywatch_ensure_daily_partitions('metric_samples', 3);
SELECT skywatch_ensure_daily_partitions('heartbeats', 3);

-- ---------------------------------------------------------------------------
-- Metric catalogue (normalized keys used by every provider and the agent)
-- ---------------------------------------------------------------------------
INSERT INTO metric_definitions(key, unit, kind, category, description) VALUES
 ('cpu.utilization',        'percent',  'gauge', 'cpu',     'CPU utilization across all cores'),
 ('cpu.core.utilization',   'percent',  'gauge', 'cpu',     'Per-core CPU utilization (series core=N)'),
 ('cpu.load1',              'load',     'gauge', 'cpu',     '1-minute load average'),
 ('cpu.load5',              'load',     'gauge', 'cpu',     '5-minute load average'),
 ('cpu.load15',             'load',     'gauge', 'cpu',     '15-minute load average'),
 ('cpu.iowait',             'percent',  'gauge', 'cpu',     'CPU time waiting on I/O'),
 ('cpu.steal',              'percent',  'gauge', 'cpu',     'CPU time stolen by the hypervisor'),
 ('cpu.credits_remaining',  'count',    'gauge', 'cpu',     'Burstable VM CPU credits remaining'),
 ('memory.total_bytes',     'bytes',    'gauge', 'memory',  'Total physical memory'),
 ('memory.used_bytes',      'bytes',    'gauge', 'memory',  'Used physical memory'),
 ('memory.available_bytes', 'bytes',    'gauge', 'memory',  'Available physical memory'),
 ('memory.utilization',     'percent',  'gauge', 'memory',  'Memory utilization'),
 ('memory.swap_utilization','percent',  'gauge', 'memory',  'Swap / page file utilization'),
 ('disk.total_bytes',       'bytes',    'gauge', 'disk',    'Filesystem capacity (series mount=...)'),
 ('disk.used_bytes',        'bytes',    'gauge', 'disk',    'Filesystem used bytes (series mount=...)'),
 ('disk.free_bytes',        'bytes',    'gauge', 'disk',    'Filesystem free bytes (series mount=...)'),
 ('disk.utilization',       'percent',  'gauge', 'disk',    'Filesystem utilization (series mount=...)'),
 ('disk.read_bytes_per_sec','bytes/s',  'rate',  'disk',    'Disk read throughput'),
 ('disk.write_bytes_per_sec','bytes/s', 'rate',  'disk',    'Disk write throughput'),
 ('disk.read_ops_per_sec',  'ops/s',    'rate',  'disk',    'Disk read IOPS'),
 ('disk.write_ops_per_sec', 'ops/s',    'rate',  'disk',    'Disk write IOPS'),
 ('net.in_bytes_per_sec',   'bytes/s',  'rate',  'network', 'Inbound network throughput'),
 ('net.out_bytes_per_sec',  'bytes/s',  'rate',  'network', 'Outbound network throughput'),
 ('net.in_packets_per_sec', 'packets/s','rate',  'network', 'Inbound packets'),
 ('net.out_packets_per_sec','packets/s','rate',  'network', 'Outbound packets'),
 ('net.errors_per_sec',     'errors/s', 'rate',  'network', 'Interface errors (in+out)'),
 ('net.drops_per_sec',      'drops/s',  'rate',  'network', 'Interface drops (in+out)'),
 ('net.tcp_established',    'count',    'gauge', 'network', 'Established TCP connections'),
 ('vm.availability',        'ratio',    'gauge', 'health',  'Provider-reported VM availability (0..1)'),
 ('synthetic.latency_ms',   'ms',       'gauge', 'synthetic','Synthetic check response time'),
 ('synthetic.success',      'ratio',    'gauge', 'synthetic','Synthetic check success (1/0)'),
 ('tls.days_to_expiry',     'days',     'gauge', 'synthetic','Days until TLS certificate expiry'),
 ('db.cpu_utilization',     'percent',  'gauge', 'database','Managed database CPU utilization'),
 ('db.storage_utilization', 'percent',  'gauge', 'database','Managed database storage utilization'),
 ('db.connections',         'count',    'gauge', 'database','Managed database active connections'),
 ('lb.healthy_backends',    'count',    'gauge', 'network', 'Load balancer healthy backend count'),
 ('lb.data_path_availability','percent','gauge', 'network', 'Load balancer data path availability'),
 ('app.http_5xx',           'count',    'gauge', 'app',     'HTTP 5xx responses in the interval'),
 ('app.response_time_ms',   'ms',       'gauge', 'app',     'Average response time'),
 ('storage.availability',   'percent',  'gauge', 'storage', 'Storage service availability');
