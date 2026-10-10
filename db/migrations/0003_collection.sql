-- Collection pipeline refinements.

-- Idempotent ingestion: re-delivered agent batches and overlapping provider windows
-- must not duplicate samples. (Unique indexes on partitioned tables must include ts.)
DROP INDEX IF EXISTS metric_samples_lookup;
CREATE UNIQUE INDEX metric_samples_identity ON metric_samples(resource_id, metric, series, ts, source);

-- Provider-side guest heartbeat (e.g. Azure Monitor Agent Heartbeat table).
ALTER TABLE resources ADD COLUMN guest_heartbeat_at timestamptz;
ALTER TABLE resources ADD COLUMN guest_heartbeat_source text;
ALTER TABLE resources ADD COLUMN provider_health_at timestamptz;
-- Metrics a provider could not return for this resource, with the reason
-- ({"memory.utilization": "requires guest agent"}). Shown in the UI instead of blanks.
ALTER TABLE resources ADD COLUMN metric_gaps jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE resources ADD COLUMN flapping boolean NOT NULL DEFAULT false;

ALTER TABLE collection_jobs DROP CONSTRAINT collection_jobs_kind_check;
ALTER TABLE collection_jobs ADD CONSTRAINT collection_jobs_kind_check
  CHECK (kind IN ('discovery','metrics','health','heartbeat','events'));

ALTER TABLE escalation_policies ADD COLUMN is_default boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX escalation_policies_default ON escalation_policies(org_id) WHERE is_default;

-- Reachability checks linked to a resource feed the host-liveness decision.
ALTER TABLE synthetic_checks ADD COLUMN counts_for_liveness boolean NOT NULL DEFAULT false;
ALTER TABLE synthetic_checks DROP CONSTRAINT synthetic_checks_kind_check;
ALTER TABLE synthetic_checks ADD CONSTRAINT synthetic_checks_kind_check
  CHECK (kind IN ('http','tcp','dns','tls','icmp'));

-- Private probes run inside customer networks and pull their checks over HTTPS.
CREATE TABLE probes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name          text NOT NULL,
  location      text NOT NULL,
  secret_hash   bytea NOT NULL,
  version       text,
  last_seen_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, location)
);
ALTER TABLE probes ENABLE ROW LEVEL SECURITY;
ALTER TABLE probes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON probes USING (org_id = app_org_id()) WITH CHECK (org_id = app_org_id());

INSERT INTO metric_definitions(key, unit, kind, category, description) VALUES
 ('firewall.health', 'percent', 'gauge', 'network', 'Azure Firewall health state percentage'),
 ('agent.queue_depth', 'count', 'gauge', 'agent', 'Batches buffered in the agent local queue'),
 ('agent.cpu_percent', 'percent', 'gauge', 'agent', 'Agent process CPU usage'),
 ('agent.rss_bytes', 'bytes', 'gauge', 'agent', 'Agent process resident memory'),
 ('system.uptime_seconds', 'seconds', 'gauge', 'system', 'Host uptime')
ON CONFLICT (key) DO NOTHING;
