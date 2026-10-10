-- Rollups keep the source so long-range charts never blend agent data with provider
-- data for the same metric.
ALTER TABLE metric_rollups_1h ADD COLUMN source text NOT NULL DEFAULT 'unknown';
ALTER TABLE metric_rollups_1h DROP CONSTRAINT metric_rollups_1h_pkey;
ALTER TABLE metric_rollups_1h ADD PRIMARY KEY (resource_id, metric, series, source, bucket);

-- Default monitoring policy, escalation policy and alert rules for a new organization.
-- These are the documented starting policies, not universal rules: every value is
-- editable per organization, and rules support per-OS/volume/environment exclusions.
CREATE OR REPLACE FUNCTION skywatch_init_org(p_org uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Callers subject to RLS may only initialise the organization they are scoped to.
  IF session_user = 'skywatch_api' AND app_org_id() IS DISTINCT FROM p_org THEN
    RAISE EXCEPTION 'skywatch_init_org: organization not in session scope';
  END IF;
  INSERT INTO monitoring_policies(org_id, name, is_default, watched_services)
  VALUES (p_org, 'Default policy', true, '{"linux":["sshd"],"windows":[]}')
  ON CONFLICT DO NOTHING;

  INSERT INTO escalation_policies(org_id, name, is_default, steps, repeat_interval_s, notify_on_resolve)
  SELECT p_org, 'Default escalation', true, '[]', 3600, true
  WHERE NOT EXISTS (SELECT 1 FROM escalation_policies WHERE org_id = p_org AND is_default);

  IF NOT EXISTS (SELECT 1 FROM alert_rules WHERE org_id = p_org) THEN
    INSERT INTO alert_rules(org_id, name, description, kind, metric, series_match, operator, threshold, recovery_threshold, for_seconds, severity) VALUES
      (p_org, 'CPU high', 'CPU above 85% for 5 minutes', 'metric_threshold', 'cpu.utilization', NULL, '>', 85, 80, 300, 'warning'),
      (p_org, 'CPU critical', 'CPU above 95% for 5 minutes', 'metric_threshold', 'cpu.utilization', NULL, '>', 95, 90, 300, 'critical'),
      (p_org, 'Memory high', 'Memory above 85% for 5 minutes', 'metric_threshold', 'memory.utilization', NULL, '>', 85, 80, 300, 'warning'),
      (p_org, 'Disk space low', 'Volume utilization above 80%', 'metric_threshold', 'disk.utilization', 'mount=*', '>', 80, 78, 0, 'warning'),
      (p_org, 'Disk space critical', 'Volume utilization above 90%', 'metric_threshold', 'disk.utilization', 'mount=*', '>', 90, 88, 0, 'critical');
    INSERT INTO alert_rules(org_id, name, description, kind, threshold, for_seconds, consecutive, severity) VALUES
      (p_org, 'Heartbeat missing', 'No agent heartbeat for 5 minutes', 'heartbeat', 300, 0, 1, 'critical'),
      (p_org, 'Required service stopped', 'A service marked as required is not running', 'service_state', NULL, 0, 1, 'critical'),
      (p_org, 'Synthetic check failing', 'Two consecutive synthetic check failures', 'synthetic', NULL, 0, 2, 'critical'),
      (p_org, 'Provider reports unavailable', 'Cloud provider health API reports the resource unavailable', 'provider_state', NULL, 0, 1, 'critical');
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skywatch_api') THEN
    GRANT EXECUTE ON FUNCTION skywatch_init_org(uuid) TO skywatch_api;
  END IF;
END $$;
