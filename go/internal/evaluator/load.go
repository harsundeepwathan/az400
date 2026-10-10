package evaluator

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/harsundeepwathan/az400/go/internal/alerting"
	"github.com/harsundeepwathan/az400/go/internal/health"
	"github.com/harsundeepwathan/az400/go/internal/model"
)

type resource struct {
	ID, Provider, AccountID, Type, Name, Region, Environment, OSType string
	PowerState                                                       model.PowerState
	ProviderHealth                                                   model.ProviderHealth
	ProviderHealthReason                                             string
	ProviderHealthAt                                                 *time.Time
	GuestHeartbeatAt                                                 *time.Time
	GuestHeartbeatSource                                             string
	State                                                            model.OperationalState
	StateReason                                                      string
	StateSince                                                       time.Time
	LastTelemetry                                                    *time.Time
	Flapping                                                         bool
	Tags                                                             map[string]string
}

func (r *resource) subject() alerting.Subject {
	return alerting.Subject{ID: r.ID, Provider: r.Provider, Type: r.Type, Environment: r.Environment,
		OSType: r.OSType, Region: r.Region, AccountID: r.AccountID, Tags: r.Tags}
}

type agentInfo struct {
	ID            string
	LastHeartbeat *time.Time
}

type accountInfo struct {
	ID, Name, Status, Reason string
	LastSuccess              *time.Time
}

type serviceCheck struct {
	ID, ResourceID, Name, Display, Expected, Current string
	Critical                                         bool
	LastReported                                     *time.Time
}

type synthCheck struct {
	ID, Name, Kind, ResourceID string
	Liveness                   bool
	LastOK                     *bool
	LastRun                    *time.Time
	Failures                   int
	Interval                   time.Duration
}

type maintWindow struct {
	Name  string
	Scope alerting.Scope
}

type ruleRow struct {
	alerting.Rule
	EscalationPolicyID *string
}

type instanceKey struct{ Rule, Subject, Series string }

type instanceRow struct {
	ID         string
	Key        instanceKey
	ResourceID *string
	alerting.Instance
	IncidentID *string
	Summary    string
	Suppressed *string
}

type orgState struct {
	OrgID       string
	Now         time.Time
	Policy      health.HeartbeatPolicy
	FlapWindow  time.Duration
	FlapCount   int
	Resources   map[string]*resource
	Agents      map[string]agentInfo // by resource id
	Accounts    map[string]accountInfo
	Services    []serviceCheck
	Synthetics  []synthCheck
	Maintenance []maintWindow
	Rules       []ruleRow
	Instances   map[instanceKey]*instanceRow
	IngestDown  bool
}

func (e *Evaluator) load(ctx context.Context, tx pgx.Tx, orgID string, now time.Time, ingestDown bool) (*orgState, error) {
	st := &orgState{OrgID: orgID, Now: now, Policy: health.DefaultHeartbeatPolicy, FlapWindow: 15 * time.Minute, FlapCount: 4,
		Resources: map[string]*resource{}, Agents: map[string]agentInfo{}, Accounts: map[string]accountInfo{},
		Instances: map[instanceKey]*instanceRow{}, IngestDown: ingestDown}

	var iv, warn, crit, fw int
	err := tx.QueryRow(ctx, `SELECT heartbeat_interval_s, heartbeat_warning_s, heartbeat_critical_s, flap_window_s, flap_threshold
		FROM monitoring_policies WHERE org_id=$1 AND is_default`, orgID).Scan(&iv, &warn, &crit, &fw, &st.FlapCount)
	if err == nil {
		st.Policy = health.HeartbeatPolicy{Interval: secs(iv), Warning: secs(warn), Critical: secs(crit)}
		st.FlapWindow = secs(fw)
	} else if err != pgx.ErrNoRows {
		return nil, err
	}

	rows, err := tx.Query(ctx, `SELECT r.id, r.provider, coalesce(r.cloud_account_id::text,''), r.resource_type, r.name, coalesce(r.region,''),
			coalesce(r.environment,''), coalesce(r.os_type,''), r.power_state, r.provider_health, coalesce(r.provider_health_reason,''),
			r.provider_health_at, r.guest_heartbeat_at, coalesce(r.guest_heartbeat_source,''), r.operational_state, coalesce(r.state_reason,''),
			r.state_since, r.last_telemetry_at, r.flapping,
			coalesce((SELECT jsonb_object_agg(key, value) FROM resource_tags t WHERE t.resource_id = r.id), '{}')
		FROM resources r WHERE r.org_id=$1 AND r.deleted_at IS NULL AND r.monitoring_enabled`, orgID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		r := &resource{}
		var ps, ph, state string
		var tags []byte
		if err := rows.Scan(&r.ID, &r.Provider, &r.AccountID, &r.Type, &r.Name, &r.Region, &r.Environment, &r.OSType, &ps, &ph,
			&r.ProviderHealthReason, &r.ProviderHealthAt, &r.GuestHeartbeatAt, &r.GuestHeartbeatSource, &state, &r.StateReason,
			&r.StateSince, &r.LastTelemetry, &r.Flapping, &tags); err != nil {
			rows.Close()
			return nil, err
		}
		r.PowerState, r.ProviderHealth, r.State = model.PowerState(ps), model.ProviderHealth(ph), model.OperationalState(state)
		_ = json.Unmarshal(tags, &r.Tags)
		st.Resources[r.ID] = r
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	rows, err = tx.Query(ctx, `SELECT DISTINCT ON (resource_id) resource_id, id, last_heartbeat_at FROM agents
		WHERE org_id=$1 AND status='active' AND resource_id IS NOT NULL ORDER BY resource_id, enrolled_at DESC`, orgID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var rid string
		var a agentInfo
		if err := rows.Scan(&rid, &a.ID, &a.LastHeartbeat); err != nil {
			rows.Close()
			return nil, err
		}
		st.Agents[rid] = a
	}
	rows.Close()

	rows, err = tx.Query(ctx, `SELECT id, name, status, coalesce(status_reason,''), last_success_at FROM cloud_accounts WHERE org_id=$1`, orgID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var a accountInfo
		if err := rows.Scan(&a.ID, &a.Name, &a.Status, &a.Reason, &a.LastSuccess); err != nil {
			rows.Close()
			return nil, err
		}
		st.Accounts[a.ID] = a
	}
	rows.Close()

	rows, err = tx.Query(ctx, `SELECT id, resource_id, name, coalesce(display_name,''), expected_state, coalesce(current_state,'unknown'),
		critical, last_reported_at FROM service_checks WHERE org_id=$1 AND expected_state <> 'any'`, orgID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var s serviceCheck
		if err := rows.Scan(&s.ID, &s.ResourceID, &s.Name, &s.Display, &s.Expected, &s.Current, &s.Critical, &s.LastReported); err != nil {
			rows.Close()
			return nil, err
		}
		st.Services = append(st.Services, s)
	}
	rows.Close()

	rows, err = tx.Query(ctx, `SELECT id, name, kind, coalesce(resource_id::text,''), counts_for_liveness, last_ok, last_run_at,
		consecutive_failures, interval_seconds FROM synthetic_checks WHERE org_id=$1 AND enabled`, orgID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var s synthCheck
		var ivs int
		if err := rows.Scan(&s.ID, &s.Name, &s.Kind, &s.ResourceID, &s.Liveness, &s.LastOK, &s.LastRun, &s.Failures, &ivs); err != nil {
			rows.Close()
			return nil, err
		}
		s.Interval = secs(ivs)
		st.Synthetics = append(st.Synthetics, s)
	}
	rows.Close()

	rows, err = tx.Query(ctx, `SELECT name, scope FROM maintenance_windows WHERE org_id=$1 AND starts_at <= $2 AND ends_at > $2`, orgID, now)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var m maintWindow
		var scope []byte
		if err := rows.Scan(&m.Name, &scope); err != nil {
			rows.Close()
			return nil, err
		}
		_ = json.Unmarshal(scope, &m.Scope)
		st.Maintenance = append(st.Maintenance, m)
	}
	rows.Close()

	rows, err = tx.Query(ctx, `SELECT id, name, kind, coalesce(metric,''), coalesce(series_match,''), aggregation, coalesce(operator,'>'),
			coalesce(threshold,0), recovery_threshold, for_seconds, consecutive, severity, scope, exclusions, escalation_policy_id
		FROM alert_rules WHERE org_id=$1 AND enabled`, orgID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var r ruleRow
		var kind, sev string
		var forS int
		var scope, excl []byte
		if err := rows.Scan(&r.ID, &r.Name, &kind, &r.Metric, &r.SeriesMatch, &r.Aggregation, &r.Operator, &r.Threshold,
			&r.RecoveryThreshold, &forS, &r.Consecutive, &sev, &scope, &excl, &r.EscalationPolicyID); err != nil {
			rows.Close()
			return nil, err
		}
		r.Kind, r.Severity, r.For = alerting.Kind(kind), model.Severity(sev), secs(forS)
		_ = json.Unmarshal(scope, &r.Scope)
		_ = json.Unmarshal(excl, &r.Exclusions)
		st.Rules = append(st.Rules, r)
	}
	rows.Close()

	rows, err = tx.Query(ctx, `SELECT id, rule_id, subject_id, series, resource_id, state, pending_since, firing_since, resolved_at,
		breaches, coalesce(value, 'NaN'), incident_id, coalesce(summary,''), suppressed_reason FROM alert_instances WHERE org_id=$1`, orgID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		in := &instanceRow{}
		var state string
		if err := rows.Scan(&in.ID, &in.Key.Rule, &in.Key.Subject, &in.Key.Series, &in.ResourceID, &state, &in.PendingSince,
			&in.FiringSince, &in.ResolvedAt, &in.Breaches, &in.Value, &in.IncidentID, &in.Summary, &in.Suppressed); err != nil {
			rows.Close()
			return nil, err
		}
		in.State = alerting.State(state)
		st.Instances[in.Key] = in
	}
	rows.Close()
	return st, rows.Err()
}

// inMaintenance returns the active maintenance window covering the resource, if any.
func (st *orgState) inMaintenance(r *resource) (string, bool) {
	for _, m := range st.Maintenance {
		if m.Scope.Matches(r.subject()) {
			return m.Name, true
		}
	}
	return "", false
}

// accountDegraded reports whether provider-sourced signals for r are untrustworthy.
func (st *orgState) accountDegraded(r *resource) (bool, string) {
	if r.AccountID == "" {
		return false, ""
	}
	a, ok := st.Accounts[r.AccountID]
	if !ok {
		return false, ""
	}
	switch a.Status {
	case "error", "degraded":
		return true, a.Reason
	}
	if a.LastSuccess == nil || st.Now.Sub(*a.LastSuccess) > 20*time.Minute {
		return true, "no successful collection from " + a.Name + " in the last 20 minutes"
	}
	return false, ""
}

func secs(n int) time.Duration { return time.Duration(n) * time.Second }

// metricPoints loads per-minute aggregates for the metrics used by metric rules.
// When several sources report the same metric for a resource (e.g. the Skywatch agent
// and Azure Monitor both report CPU), the agent's data is preferred.
func (e *Evaluator) metricPoints(ctx context.Context, tx pgx.Tx, st *orgState) (map[string]map[string]map[string][]aggPoint, error) {
	metrics := map[string]bool{}
	maxFor := time.Duration(0)
	for _, r := range st.Rules {
		if r.Kind == alerting.KindMetric && r.Metric != "" {
			metrics[r.Metric] = true
			if r.For > maxFor {
				maxFor = r.For
			}
		}
	}
	out := map[string]map[string]map[string][]aggPoint{} // resource -> metric -> series -> points
	if len(metrics) == 0 {
		return out, nil
	}
	list := make([]string, 0, len(metrics))
	for m := range metrics {
		list = append(list, m)
	}
	since := st.Now.Add(-(maxFor + e.cfg.StaleAfter + 5*time.Minute))
	rows, err := tx.Query(ctx, `
		WITH agg AS (
			SELECT resource_id, metric, series, source, date_trunc('minute', ts) AS b,
			       avg(value) AS avg, min(value) AS min, max(value) AS max,
			       (array_agg(value ORDER BY ts DESC))[1] AS last
			FROM metric_samples WHERE org_id=$1 AND metric = ANY($2) AND ts > $3
			GROUP BY 1,2,3,4,5),
		pick AS (
			SELECT DISTINCT ON (resource_id, metric) resource_id, metric, source
			FROM (SELECT resource_id, metric, source, max(b) AS mb FROM agg GROUP BY 1,2,3) x
			ORDER BY resource_id, metric, (source = 'agent') DESC, mb DESC)
		SELECT a.resource_id, a.metric, a.series, a.b, a.avg, a.min, a.max, a.last
		FROM agg a JOIN pick p USING (resource_id, metric, source)
		ORDER BY a.b`, st.OrgID, list, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var rid, metric, series string
		var p aggPoint
		if err := rows.Scan(&rid, &metric, &series, &p.TS, &p.Avg, &p.Min, &p.Max, &p.Last); err != nil {
			return nil, err
		}
		if out[rid] == nil {
			out[rid] = map[string]map[string][]aggPoint{}
		}
		if out[rid][metric] == nil {
			out[rid][metric] = map[string][]aggPoint{}
		}
		out[rid][metric][series] = append(out[rid][metric][series], p)
	}
	return out, rows.Err()
}

type aggPoint struct {
	TS                  time.Time
	Avg, Min, Max, Last float64
}

func (p aggPoint) value(agg string) float64 {
	switch agg {
	case "min":
		return p.Min
	case "max":
		return p.Max
	case "last":
		return p.Last
	}
	return p.Avg
}
