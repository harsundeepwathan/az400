-- Agent ingestion support.

-- Batch idempotency: a batch re-sent after a lost acknowledgement is acknowledged again
-- without being re-applied. Rows are purged after 48 hours by the maintenance job.
CREATE TABLE agent_batches (
  batch_id     uuid PRIMARY KEY,
  org_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  agent_id     uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  seq          bigint NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX agent_batches_received ON agent_batches(received_at);
ALTER TABLE agent_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_batches FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON agent_batches USING (org_id = app_org_id()) WITH CHECK (org_id = app_org_id());

ALTER TABLE agents ADD COLUMN machine_id text;
ALTER TABLE agents ADD COLUMN collector_errors jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE agents ADD COLUMN host_info jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE agents ADD COLUMN last_ip inet;

-- Services every matching host must run, e.g. {"linux":["sshd"],"windows":["W32Time"]}.
ALTER TABLE monitoring_policies ADD COLUMN watched_services jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE monitoring_policies ADD COLUMN discover_services boolean NOT NULL DEFAULT true;
