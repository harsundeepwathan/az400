// Package evaluator periodically evaluates alert rules, manages incidents, computes
// resource operational state and schedules notifications.
//
// Exactly one evaluator is active at a time: instances compete for a PostgreSQL
// advisory lock held on a dedicated connection; the others stay on standby and take
// over when the leader's session ends.
package evaluator

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/alerting"
	"github.com/harsundeepwathan/az400/go/internal/health"
	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/selfmon"
)

const leaderLockKey = 727274002

// Config for the evaluator.
type Config struct {
	Interval   time.Duration // cycle interval, default 30s
	StaleAfter time.Duration // metric data older than this is "no data", default 15m
	// BurstThreshold new incidents in one account+region within BurstWindow are grouped
	// under a parent incident (storm control). Default 3 in 5 minutes.
	BurstThreshold int
	BurstWindow    time.Duration
	// ReopenWindow: an incident auto-resolved less than this ago is reopened instead of
	// creating a new one when the same condition fires again (flap suppression).
	ReopenWindow time.Duration
	// ProviderHealthStale: provider health older than this is not trusted.
	ProviderHealthStale time.Duration
}

// Evaluator runs evaluation cycles.
type Evaluator struct {
	pool *pgxpool.Pool
	cfg  Config
	log  *slog.Logger
	now  func() time.Time
}

// New creates an evaluator.
func New(pool *pgxpool.Pool, cfg Config, log *slog.Logger) *Evaluator {
	if cfg.Interval <= 0 {
		cfg.Interval = 30 * time.Second
	}
	if cfg.StaleAfter <= 0 {
		cfg.StaleAfter = 15 * time.Minute
	}
	if cfg.BurstThreshold <= 0 {
		cfg.BurstThreshold = 3
	}
	if cfg.BurstWindow <= 0 {
		cfg.BurstWindow = 5 * time.Minute
	}
	if cfg.ReopenWindow <= 0 {
		cfg.ReopenWindow = 10 * time.Minute
	}
	if cfg.ProviderHealthStale <= 0 {
		cfg.ProviderHealthStale = 20 * time.Minute
	}
	return &Evaluator{pool: pool, cfg: cfg, log: log, now: time.Now}
}

// SetClock overrides the clock (tests).
func (e *Evaluator) SetClock(f func() time.Time) { e.now = f }

// Run evaluates until ctx is cancelled, only while holding leadership.
func (e *Evaluator) Run(ctx context.Context) error {
	for ctx.Err() == nil {
		conn, err := e.pool.Acquire(ctx)
		if err != nil {
			e.sleep(ctx, 5*time.Second)
			continue
		}
		var leader bool
		if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, leaderLockKey).Scan(&leader); err != nil || !leader {
			conn.Release()
			e.sleep(ctx, 15*time.Second)
			continue
		}
		e.log.Info("evaluator acquired leadership")
		t := time.NewTicker(e.cfg.Interval)
		for ctx.Err() == nil {
			if err := e.Cycle(ctx); err != nil && ctx.Err() == nil {
				e.log.Error("evaluation cycle", "err", err)
			}
			// Verify the lock connection is still alive; if not, re-contend.
			if err := conn.Ping(ctx); err != nil {
				break
			}
			select {
			case <-ctx.Done():
			case <-t.C:
			}
		}
		t.Stop()
		_, _ = conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, leaderLockKey)
		conn.Release()
	}
	return nil
}

func (e *Evaluator) sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// Cycle runs one evaluation over every organization.
func (e *Evaluator) Cycle(ctx context.Context) error {
	start := time.Now()
	now := e.now().UTC()
	ingestDown, err := e.ingestDegraded(ctx, now)
	if err != nil {
		return err
	}
	rows, err := e.pool.Query(ctx, `SELECT id FROM organizations ORDER BY id`)
	if err != nil {
		return err
	}
	var orgs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		orgs = append(orgs, id)
	}
	rows.Close()
	var firstErr error
	for _, org := range orgs {
		if err := e.evaluateOrg(ctx, org, now, ingestDown); err != nil {
			selfmon.EvaluatorCycles.WithLabelValues("error").Inc()
			e.log.Error("evaluate org", "org", org, "err", err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	if firstErr == nil {
		selfmon.EvaluatorCycles.WithLabelValues("ok").Inc()
	}
	selfmon.EvaluatorDuration.Observe(time.Since(start).Seconds())
	return firstErr
}

// ingestDegraded reports whether the platform's agent ingestion path is unhealthy, in
// which case silent agents are not evidence of host problems. It is degraded when no
// ingest instance has heartbeated recently, or when heartbeats from all agents stopped
// at once although several agents were reporting shortly before.
func (e *Evaluator) ingestDegraded(ctx context.Context, now time.Time) (bool, error) {
	var ingestAlive bool
	var recent, before int
	err := e.pool.QueryRow(ctx, `SELECT
		EXISTS(SELECT 1 FROM platform_instances WHERE 'ingest' = ANY(roles) AND last_heartbeat > $1::timestamptz - interval '90 seconds'),
		(SELECT count(DISTINCT agent_id) FROM heartbeats WHERE received_at > $1::timestamptz - interval '3 minutes'),
		(SELECT count(DISTINCT agent_id) FROM heartbeats WHERE received_at BETWEEN $1::timestamptz - interval '15 minutes' AND $1::timestamptz - interval '5 minutes')`,
		now).Scan(&ingestAlive, &recent, &before)
	if err != nil {
		return false, err
	}
	return !ingestAlive || (before >= 5 && recent == 0), nil
}

type pendingIncidentOp struct {
	inst *instanceRow
	rule ruleRow
	res  *resource // nil for non-resource subjects
	tr   alerting.Transition
	sum  string
}

func (e *Evaluator) evaluateOrg(ctx context.Context, orgID string, now time.Time, ingestDown bool) error {
	tx, err := e.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Serialize per-org evaluation with API writes that touch incidents (ack/resolve).
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "eval:"+orgID); err != nil {
		return err
	}
	st, err := e.load(ctx, tx, orgID, now, ingestDown)
	if err != nil {
		return fmt.Errorf("load: %w", err)
	}
	points, err := e.metricPoints(ctx, tx, st)
	if err != nil {
		return fmt.Errorf("metrics: %w", err)
	}

	var ops []pendingIncidentOp
	seen := map[instanceKey]bool{}
	for _, rule := range st.Rules {
		for _, obs := range e.observe(st, rule, points) {
			key := instanceKey{Rule: rule.ID, Subject: obs.subject, Series: obs.series}
			seen[key] = true
			inst := st.Instances[key]
			if inst == nil {
				inst = &instanceRow{Key: key, Instance: alerting.Instance{State: alerting.StateNormal}}
				st.Instances[key] = inst
			}
			if obs.resourceID != "" {
				rid := obs.resourceID
				inst.ResourceID = &rid
			}
			next, tr := alerting.Step(rule.Rule, inst.Instance, obs.o, now)
			// Maintenance: do not start firing for resources in a maintenance window.
			if tr != nil && tr.To == alerting.StateFiring && obs.maintenance != "" {
				reason := "maintenance: " + obs.maintenance
				inst.Suppressed = &reason
				if inst.State == alerting.StateNormal || inst.State == alerting.StateResolved {
					next.State = alerting.StatePending
					next.FiringSince = nil
					tr = &alerting.Transition{From: inst.State, To: alerting.StatePending, Message: tr.Message}
				} else {
					next = inst.Instance
					tr = nil
				}
			} else if obs.maintenance == "" {
				inst.Suppressed = nil
			}
			inst.Instance = next
			if obs.o.HasData || inst.Summary == "" {
				inst.Summary = obs.summary
			}
			if err := e.saveInstance(ctx, tx, st, inst, rule, tr); err != nil {
				return err
			}
			if tr != nil {
				ops = append(ops, pendingIncidentOp{inst: inst, rule: rule, res: st.Resources[obs.resourceID], tr: *tr, sum: obs.summary})
			}
		}
	}
	// Instances whose subject disappeared (resource deleted, rule rescoped, service no
	// longer required) are resolved rather than left firing forever.
	for key, inst := range st.Instances {
		if seen[key] || inst.ID == "" || (inst.State != alerting.StateFiring && inst.State != alerting.StatePending) {
			continue
		}
		ruleKnown := false
		var rule ruleRow
		for _, r := range st.Rules {
			if r.ID == key.Rule {
				ruleKnown, rule = true, r
			}
		}
		from := inst.State
		inst.State = alerting.StateResolved
		inst.ResolvedAt = &now
		tr := alerting.Transition{From: from, To: alerting.StateResolved, Message: "Condition no longer evaluated (subject removed or rule changed)"}
		if !ruleKnown {
			rule = ruleRow{Rule: alerting.Rule{ID: key.Rule, Name: "(disabled rule)"}}
		}
		if err := e.saveInstance(ctx, tx, st, inst, rule, &tr); err != nil {
			return err
		}
		if from == alerting.StateFiring {
			var res *resource
			if inst.ResourceID != nil {
				res = st.Resources[*inst.ResourceID]
			}
			ops = append(ops, pendingIncidentOp{inst: inst, rule: rule, res: res, tr: tr, sum: inst.Summary})
		}
	}

	for _, op := range ops {
		if err := e.applyIncident(ctx, tx, st, op); err != nil {
			return fmt.Errorf("incident: %w", err)
		}
	}
	if err := e.accountIncidents(ctx, tx, st); err != nil {
		return fmt.Errorf("account incidents: %w", err)
	}
	if err := e.refreshIncidents(ctx, tx, st); err != nil {
		return fmt.Errorf("refresh incidents: %w", err)
	}
	if err := e.updateStates(ctx, tx, st, points); err != nil {
		return fmt.Errorf("states: %w", err)
	}
	if err := e.escalate(ctx, tx, st); err != nil {
		return fmt.Errorf("escalate: %w", err)
	}
	return tx.Commit(ctx)
}

type observation struct {
	subject, series, resourceID string
	o                           alerting.Observation
	summary                     string
	maintenance                 string
}

// observe produces the observations a rule makes this cycle.
func (e *Evaluator) observe(st *orgState, rule ruleRow, points map[string]map[string]map[string][]aggPoint) []observation {
	var out []observation
	now := st.Now
	switch rule.Kind {
	case alerting.KindMetric:
		for rid, r := range st.Resources {
			if !rule.Matches(r.subject()) || r.PowerState.IsOff() {
				continue
			}
			mw, _ := st.inMaintenance(r)
			for series, pts := range points[rid][rule.Metric] {
				if !rule.SeriesIncluded(series) {
					continue
				}
				ap := make([]alerting.Point, len(pts))
				for i, p := range pts {
					ap[i] = alerting.Point{TS: p.TS, Value: p.value(rule.Aggregation)}
				}
				o := alerting.EvaluateSeries(rule.Rule, ap, now, e.cfg.StaleAfter)
				label := r.Name
				switch {
				case strings.HasPrefix(series, "mount="):
					label += " volume " + strings.TrimPrefix(series, "mount=")
				case strings.HasPrefix(series, "core="):
					label += " core " + strings.TrimPrefix(series, "core=")
				case series != "":
					label += " " + series
				}
				out = append(out, observation{subject: rid, series: series, resourceID: rid, o: o, maintenance: mw,
					summary: fmt.Sprintf("%s on %s: %s (threshold %s %s)", rule.Name, label,
						alerting.FormatValue(rule.Metric, o.Value), rule.Operator, alerting.FormatValue(rule.Metric, rule.Threshold))})
			}
		}
	case alerting.KindHeartbeat:
		threshold := secs(int(rule.Threshold))
		if threshold <= 0 {
			threshold = st.Policy.Critical
		}
		for rid, r := range st.Resources {
			a, hasAgent := st.Agents[rid]
			degraded, _ := st.accountDegraded(r)
			hasGuest := r.GuestHeartbeatAt != nil && !degraded
			if (!hasAgent && !hasGuest) || !rule.Matches(r.subject()) {
				continue
			}
			// The freshest heartbeat from any source (Skywatch agent or provider-side
			// guest agent such as Azure Monitor Agent) proves the guest is alive.
			var last *time.Time
			source := "agent"
			if hasAgent && a.LastHeartbeat != nil {
				last = a.LastHeartbeat
			}
			if hasGuest && (last == nil || r.GuestHeartbeatAt.After(*last)) {
				last, source = r.GuestHeartbeatAt, r.GuestHeartbeatSource
			}
			mw, _ := st.inMaintenance(r)
			obs := observation{subject: rid, resourceID: rid, maintenance: mw}
			switch {
			case st.IngestDown && source == "agent":
				// Our own pipeline is unhealthy: hold state, never fire on missing heartbeats.
			case r.PowerState.IsOff():
				obs.o = alerting.Observation{HasData: true, Recovered: true}
				obs.summary = "Heartbeat not expected: resource " + string(r.PowerState)
			case last == nil:
				// Agent enrolled but never reported: surfaced as No Data, not as an alert.
			default:
				age := now.Sub(*last)
				if age < 0 {
					age = 0 // heartbeat newer than the evaluation clock (skew)
				}
				breach := age >= threshold
				obs.o = alerting.Observation{HasData: true, Breaching: breach, Sustained: breach, Recovered: !breach,
					Value: math.Round(age.Seconds()), LatestTS: now, BreachSince: last.Add(threshold)}
				obs.summary = fmt.Sprintf("No heartbeat from %s for %s (source: %s)", r.Name, age.Round(time.Second), source)
			}
			out = append(out, obs)
		}
	case alerting.KindServiceState:
		for _, s := range st.Services {
			r := st.Resources[s.ResourceID]
			if r == nil || !rule.Matches(r.subject()) || r.PowerState.IsOff() {
				continue
			}
			mw, _ := st.inMaintenance(r)
			obs := observation{subject: s.ID, resourceID: r.ID, maintenance: mw}
			// A service report older than 3 heartbeat intervals is stale: the heartbeat
			// rule covers silent agents, this rule only judges fresh service data.
			if s.LastReported != nil && now.Sub(*s.LastReported) <= 3*st.Policy.Interval+time.Minute {
				name := s.Name
				if s.Display != "" && s.Display != s.Name {
					name = fmt.Sprintf("%s (%s)", s.Display, s.Name)
				}
				breach := s.Current != s.Expected
				val := 0.0
				if breach {
					val = 1
				}
				obs.o = alerting.Observation{HasData: true, Breaching: breach, Sustained: breach, Recovered: !breach, Value: val, LatestTS: *s.LastReported}
				obs.summary = fmt.Sprintf("Service %s on %s is %s (expected %s)", name, r.Name, s.Current, s.Expected)
			}
			out = append(out, obs)
		}
	case alerting.KindSynthetic:
		need := rule.Consecutive
		if need < 1 {
			need = 1
		}
		for _, c := range st.Synthetics {
			var r *resource
			if c.ResourceID != "" {
				r = st.Resources[c.ResourceID]
			}
			if r != nil && !rule.Matches(r.subject()) {
				continue
			}
			if r == nil && len(rule.Scope.ResourceIDs) > 0 {
				continue
			}
			obs := observation{subject: c.ID}
			if r != nil {
				obs.resourceID = r.ID
				obs.maintenance, _ = st.inMaintenance(r)
			}
			if c.LastRun != nil && c.LastOK != nil && now.Sub(*c.LastRun) <= 3*c.Interval+time.Minute {
				breach := c.Failures >= need
				obs.o = alerting.Observation{HasData: true, Breaching: breach, Sustained: breach, Recovered: *c.LastOK,
					Value: float64(c.Failures), LatestTS: *c.LastRun}
				if breach {
					obs.summary = fmt.Sprintf("%s check %q failing (%d consecutive failures)", strings.ToUpper(c.Kind), c.Name, c.Failures)
				} else {
					obs.summary = fmt.Sprintf("%s check %q passing", strings.ToUpper(c.Kind), c.Name)
				}
			}
			out = append(out, obs)
		}
	case alerting.KindProviderState:
		for rid, r := range st.Resources {
			if !rule.Matches(r.subject()) || r.PowerState.IsOff() {
				continue
			}
			mw, _ := st.inMaintenance(r)
			obs := observation{subject: rid, resourceID: rid, maintenance: mw}
			degraded, _ := st.accountDegraded(r)
			fresh := r.ProviderHealthAt != nil && now.Sub(*r.ProviderHealthAt) <= e.cfg.ProviderHealthStale
			if fresh && !degraded && r.ProviderHealth != model.HealthUnknown {
				breach := r.ProviderHealth == model.HealthUnavailable ||
					(r.ProviderHealth == model.HealthDegraded && rule.Severity == model.SeverityWarning)
				obs.o = alerting.Observation{HasData: true, Breaching: breach, Sustained: breach,
					Recovered: r.ProviderHealth == model.HealthAvailable, LatestTS: *r.ProviderHealthAt}
				obs.summary = fmt.Sprintf("Provider reports %s as %s", r.Name, r.ProviderHealth)
				if r.ProviderHealthReason != "" {
					obs.summary += ": " + r.ProviderHealthReason
				}
			}
			out = append(out, obs)
		}
	}
	return out
}

func (e *Evaluator) saveInstance(ctx context.Context, tx pgx.Tx, st *orgState, inst *instanceRow, rule ruleRow, tr *alerting.Transition) error {
	var val *float64
	if !math.IsNaN(inst.Value) {
		v := inst.Value
		val = &v
	}
	err := tx.QueryRow(ctx, `INSERT INTO alert_instances(org_id, rule_id, resource_id, subject_id, series, state, value, summary,
			pending_since, firing_since, resolved_at, last_eval_at, breaches, suppressed_reason, incident_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
		ON CONFLICT (rule_id, subject_id, series) DO UPDATE SET resource_id=EXCLUDED.resource_id, state=EXCLUDED.state,
			value=EXCLUDED.value, summary=EXCLUDED.summary, pending_since=EXCLUDED.pending_since, firing_since=EXCLUDED.firing_since,
			resolved_at=EXCLUDED.resolved_at, last_eval_at=EXCLUDED.last_eval_at, breaches=EXCLUDED.breaches,
			suppressed_reason=EXCLUDED.suppressed_reason, incident_id=EXCLUDED.incident_id
		RETURNING id`,
		st.OrgID, inst.Key.Rule, inst.ResourceID, inst.Key.Subject, inst.Key.Series, string(inst.State), val, inst.Summary,
		inst.PendingSince, inst.FiringSince, inst.ResolvedAt, st.Now, inst.Breaches, inst.Suppressed, inst.IncidentID).Scan(&inst.ID)
	if err != nil {
		return err
	}
	if tr != nil {
		_, err = tx.Exec(ctx, `INSERT INTO alert_events(org_id, alert_instance_id, rule_id, resource_id, from_state, to_state, value, message, at)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, st.OrgID, inst.ID, rule.ID, inst.ResourceID, string(tr.From), string(tr.To), val, inst.Summary, st.Now)
	}
	return err
}

// --- incidents ------------------------------------------------------------------------

func dedupKey(op pendingIncidentOp) string {
	if op.res != nil {
		return "resource:" + op.res.ID
	}
	return "subject:" + op.inst.Key.Subject
}

func (e *Evaluator) applyIncident(ctx context.Context, tx pgx.Tx, st *orgState, op pendingIncidentOp) error {
	switch op.tr.To {
	case alerting.StateFiring:
		return e.openOrAttach(ctx, tx, st, op)
	case alerting.StateResolved:
		return e.alertResolved(ctx, tx, st, op)
	}
	return nil
}

func (e *Evaluator) openOrAttach(ctx context.Context, tx pgx.Tx, st *orgState, op pendingIncidentOp) error {
	key := dedupKey(op)
	var accountID *string
	title := op.sum
	if op.res != nil {
		title = fmt.Sprintf("%s: %s", op.res.Name, op.rule.Name)
		if op.res.AccountID != "" {
			a := op.res.AccountID
			accountID = &a
		}
	}
	// 1. Existing open incident for this resource: attach and maybe raise severity.
	var incID, status, severity string
	err := tx.QueryRow(ctx, `SELECT id, status, severity FROM incidents WHERE org_id=$1 AND dedup_key=$2 AND status <> 'resolved'`,
		st.OrgID, key).Scan(&incID, &status, &severity)
	switch {
	case err == nil:
		if op.rule.Severity == model.SeverityCritical && severity != "critical" {
			if _, err := tx.Exec(ctx, `UPDATE incidents SET severity='critical', title=$2 WHERE id=$1`, incID, title); err != nil {
				return err
			}
			if err := e.timeline(ctx, tx, st, incID, "severity_raised", "Severity raised to critical: "+op.sum, nil); err != nil {
				return err
			}
			if err := e.enqueueForIncident(ctx, tx, st, incID, "severity_raised"); err != nil {
				return err
			}
		}
		if err := e.timeline(ctx, tx, st, incID, "alert_firing", op.sum, map[string]any{"rule": op.rule.Name, "alert_instance_id": op.inst.ID}); err != nil {
			return err
		}
	case err == pgx.ErrNoRows:
		// 2. Recently auto-resolved incident with the same key: reopen (flap suppression).
		err = tx.QueryRow(ctx, `UPDATE incidents SET status='open', resolved_at=NULL, resolution=NULL, last_observed_at=$3,
				severity=$4, acknowledged_at=NULL, acknowledged_by=NULL
			WHERE id = (SELECT id FROM incidents WHERE org_id=$1 AND dedup_key=$2 AND status='resolved' AND resolution='auto'
				AND resolved_at > $3::timestamptz - $5::interval ORDER BY resolved_at DESC LIMIT 1)
			RETURNING id`, st.OrgID, key, st.Now, string(op.rule.Severity), fmt.Sprintf("%d seconds", int(e.cfg.ReopenWindow.Seconds()))).Scan(&incID)
		if err == nil {
			if err := e.timeline(ctx, tx, st, incID, "reopened", "Reopened: condition returned within "+e.cfg.ReopenWindow.String()+" of auto-resolution: "+op.sum, nil); err != nil {
				return err
			}
			if err := e.enqueueForIncident(ctx, tx, st, incID, "reopened"); err != nil {
				return err
			}
			break
		}
		if err != pgx.ErrNoRows {
			return err
		}
		// 3. New incident.
		var resID *string
		if op.res != nil {
			resID = &op.res.ID
		}
		err = tx.QueryRow(ctx, `INSERT INTO incidents(org_id, title, severity, resource_id, cloud_account_id, dedup_key, trigger_summary,
				first_detected_at, last_observed_at, escalation_policy_id)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$8, coalesce($9, (SELECT id FROM escalation_policies WHERE org_id=$1 AND is_default)))
			RETURNING id`, st.OrgID, title, string(op.rule.Severity), resID, accountID, key, op.sum,
			firstDetected(op.inst, st.Now), op.rule.EscalationPolicyID).Scan(&incID)
		if err != nil {
			return err
		}
		if err := e.timeline(ctx, tx, st, incID, "opened", "Incident opened: "+op.sum, map[string]any{"rule": op.rule.Name}); err != nil {
			return err
		}
		suppressed, err := e.correlate(ctx, tx, st, incID, op)
		if err != nil {
			return err
		}
		if !suppressed {
			if err := e.enqueueForIncident(ctx, tx, st, incID, "opened"); err != nil {
				return err
			}
		}
	default:
		return err
	}
	op.inst.IncidentID = &incID
	_, err = tx.Exec(ctx, `UPDATE alert_instances SET incident_id=$2 WHERE id=$1`, op.inst.ID, incID)
	return err
}

func firstDetected(inst *instanceRow, now time.Time) time.Time {
	if inst.PendingSince != nil {
		return *inst.PendingSince
	}
	return now
}

// correlate links a new incident to related open incidents using infrastructure
// relationships and burst grouping. It never asserts a root cause; it records the
// evidence used. Returns true when notifications for the new incident are suppressed
// because a parent incident already notifies.
func (e *Evaluator) correlate(ctx context.Context, tx pgx.Tx, st *orgState, incID string, op pendingIncidentOp) (bool, error) {
	if op.res == nil {
		return false, nil
	}
	// Relationship-based: resources this one depends on (depends_on / member_of targets,
	// and load balancers whose backends are failing are linked to the backend incident).
	var parentID, parentTitle, relKind string
	err := tx.QueryRow(ctx, `
		SELECT i.id, i.title, rel.kind FROM (
			SELECT to_resource_id AS rid, kind FROM resource_relations WHERE from_resource_id=$2 AND kind IN ('depends_on','member_of','attached_to')
			UNION ALL
			SELECT from_resource_id, 'backend_of' FROM resource_relations WHERE to_resource_id=$2 AND kind='backend_of'
		) rel
		JOIN incidents i ON i.resource_id = rel.rid AND i.status <> 'resolved' AND i.org_id=$1 AND i.id <> $3
		ORDER BY i.first_detected_at LIMIT 1`, st.OrgID, op.res.ID, incID).Scan(&parentID, &parentTitle, &relKind)
	if err != nil && err != pgx.ErrNoRows {
		return false, err
	}
	if err == nil {
		note := fmt.Sprintf("Related by infrastructure relationship (%s) to open incident %q. Correlation is based on topology and timing; it is not a confirmed root cause.", relKind, parentTitle)
		if _, err := tx.Exec(ctx, `UPDATE incidents SET parent_incident_id=$2, correlation_note=$3 WHERE id=$1`, incID, parentID, note); err != nil {
			return false, err
		}
		if err := e.timeline(ctx, tx, st, parentID, "related_incident", "Related incident attached: "+op.sum, map[string]any{"incident_id": incID}); err != nil {
			return false, err
		}
		return true, e.timeline(ctx, tx, st, incID, "correlated", note, map[string]any{"parent_incident_id": parentID})
	}

	// Burst grouping: several resources in the same account and region failing within
	// the burst window are grouped so on-call receives one notification.
	if op.res.AccountID == "" {
		return false, nil
	}
	burstKey := "burst:" + op.res.AccountID + ":" + op.res.Region
	var existing string
	err = tx.QueryRow(ctx, `SELECT id FROM incidents WHERE org_id=$1 AND dedup_key=$2 AND status <> 'resolved'`, st.OrgID, burstKey).Scan(&existing)
	if err == nil {
		// A multi-resource incident is already open for this account and region: join it.
		if _, err := tx.Exec(ctx, `UPDATE incidents SET parent_incident_id=$2,
				correlation_note='Grouped into a multi-resource incident (same account and region, within the burst window).'
			WHERE id=$1`, incID, existing); err != nil {
			return false, err
		}
		return true, e.timeline(ctx, tx, st, existing, "related_incident", "Related incident attached: "+op.sum, map[string]any{"incident_id": incID})
	} else if err != pgx.ErrNoRows {
		return false, err
	}
	var siblings []string
	rows, err := tx.Query(ctx, `SELECT i.id FROM incidents i JOIN resources r ON r.id = i.resource_id
		WHERE i.org_id=$1 AND i.status <> 'resolved' AND i.parent_incident_id IS NULL AND i.id <> $2
		  AND r.cloud_account_id=$3 AND coalesce(r.region,'')=$4 AND i.first_detected_at > $5 AND i.dedup_key LIKE 'resource:%'`,
		st.OrgID, incID, op.res.AccountID, op.res.Region, st.Now.Add(-e.cfg.BurstWindow))
	if err != nil {
		return false, err
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return false, err
		}
		siblings = append(siblings, id)
	}
	rows.Close()
	if len(siblings)+1 < e.cfg.BurstThreshold {
		return false, nil
	}
	acct := st.Accounts[op.res.AccountID]
	region := op.res.Region
	if region == "" {
		region = "(no region)"
	}
	var parent string
	err = tx.QueryRow(ctx, `SELECT id FROM incidents WHERE org_id=$1 AND dedup_key=$2 AND status <> 'resolved'`, st.OrgID, burstKey).Scan(&parent)
	newParent := false
	if err == pgx.ErrNoRows {
		newParent = true
		err = tx.QueryRow(ctx, `INSERT INTO incidents(org_id, title, severity, cloud_account_id, dedup_key, trigger_summary, first_detected_at,
				last_observed_at, correlation_note, escalation_policy_id)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$7,$8,(SELECT id FROM escalation_policies WHERE org_id=$1 AND is_default)) RETURNING id`,
			st.OrgID, fmt.Sprintf("Multiple resources affected in %s (%s)", region, acct.Name), string(op.rule.Severity),
			op.res.AccountID, burstKey, fmt.Sprintf("%d resources in %s raised incidents within %s", len(siblings)+1, region, e.cfg.BurstWindow),
			st.Now, "Grouped because several resources in the same account and region failed within a short window. This suggests, but does not prove, a shared cause.").Scan(&parent)
	}
	if err != nil {
		return false, err
	}
	ids := append(siblings, incID)
	if _, err := tx.Exec(ctx, `UPDATE incidents SET parent_incident_id=$2,
			correlation_note='Grouped into a multi-resource incident (same account and region, within the burst window).'
		WHERE id = ANY($1) AND parent_incident_id IS NULL`, ids, parent); err != nil {
		return false, err
	}
	if err := e.timeline(ctx, tx, st, parent, "related_incident", fmt.Sprintf("%d related incidents grouped", len(ids)), map[string]any{"incident_ids": ids}); err != nil {
		return false, err
	}
	if newParent {
		if err := e.timeline(ctx, tx, st, parent, "opened", "Multi-resource incident opened", nil); err != nil {
			return false, err
		}
		if err := e.enqueueForIncident(ctx, tx, st, parent, "opened"); err != nil {
			return false, err
		}
	}
	return true, nil
}

func (e *Evaluator) alertResolved(ctx context.Context, tx pgx.Tx, st *orgState, op pendingIncidentOp) error {
	if op.inst.IncidentID == nil {
		return nil
	}
	inc := *op.inst.IncidentID
	if err := e.timeline(ctx, tx, st, inc, "alert_resolved", "Alert cleared: "+op.sum, map[string]any{"rule": op.rule.Name}); err != nil {
		return err
	}
	return nil
}

// refreshIncidents auto-resolves incidents whose alerts have all cleared, keeps
// last_observed_at current, and resolves burst parents when all children resolved.
func (e *Evaluator) refreshIncidents(ctx context.Context, tx pgx.Tx, st *orgState) error {
	if _, err := tx.Exec(ctx, `UPDATE incidents i SET last_observed_at=$2
		WHERE i.org_id=$1 AND i.status <> 'resolved' AND EXISTS (
			SELECT 1 FROM alert_instances a WHERE a.incident_id=i.id AND a.state='firing')`, st.OrgID, st.Now); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT i.id FROM incidents i
		WHERE i.org_id=$1 AND i.status <> 'resolved'
		  AND (i.dedup_key LIKE 'resource:%' OR i.dedup_key LIKE 'subject:%')
		  AND EXISTS (SELECT 1 FROM alert_instances a WHERE a.incident_id=i.id)
		  AND NOT EXISTS (SELECT 1 FROM alert_instances a WHERE a.incident_id=i.id AND a.state='firing')`, st.OrgID)
	if err != nil {
		return err
	}
	var toResolve []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		toResolve = append(toResolve, id)
	}
	rows.Close()
	sort.Strings(toResolve)
	for _, id := range toResolve {
		if err := e.resolveIncident(ctx, tx, st, id, "All alerts cleared; incident resolved automatically according to policy"); err != nil {
			return err
		}
	}
	// Multi-resource parents resolve once every grouped incident has resolved.
	rows, err = tx.Query(ctx, `SELECT p.id FROM incidents p WHERE p.org_id=$1 AND p.status <> 'resolved' AND p.dedup_key LIKE 'burst:%'
		AND NOT EXISTS (SELECT 1 FROM incidents c WHERE c.parent_incident_id=p.id AND c.status <> 'resolved')`, st.OrgID)
	if err != nil {
		return err
	}
	var parents []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		parents = append(parents, id)
	}
	rows.Close()
	for _, id := range parents {
		if err := e.resolveIncident(ctx, tx, st, id, "All grouped incidents resolved"); err != nil {
			return err
		}
	}
	return nil
}

func (e *Evaluator) resolveIncident(ctx context.Context, tx pgx.Tx, st *orgState, id, msg string) error {
	tag, err := tx.Exec(ctx, `UPDATE incidents SET status='resolved', resolved_at=$2, resolution='auto', next_escalation_at=NULL
		WHERE id=$1 AND status <> 'resolved'`, id, st.Now)
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	if err := e.timeline(ctx, tx, st, id, "resolved", msg, nil); err != nil {
		return err
	}
	return e.enqueueForIncident(ctx, tx, st, id, "resolved")
}

// accountIncidents raises an incident when a cloud integration is failing (auth errors,
// permission loss, sustained API failure) and resolves it on recovery. These incidents
// are about the monitoring path, never about customer resources.
func (e *Evaluator) accountIncidents(ctx context.Context, tx pgx.Tx, st *orgState) error {
	for _, a := range st.Accounts {
		key := "account:" + a.ID
		failing := a.Status == "error" || a.Status == "degraded"
		var incID string
		err := tx.QueryRow(ctx, `SELECT id FROM incidents WHERE org_id=$1 AND dedup_key=$2 AND status <> 'resolved'`, st.OrgID, key).Scan(&incID)
		if err != nil && err != pgx.ErrNoRows {
			return err
		}
		switch {
		case failing && err == pgx.ErrNoRows:
			sev := "warning"
			if a.Status == "error" {
				sev = "critical"
			}
			err = tx.QueryRow(ctx, `INSERT INTO incidents(org_id, title, severity, cloud_account_id, dedup_key, trigger_summary,
					first_detected_at, last_observed_at, escalation_policy_id)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$7,(SELECT id FROM escalation_policies WHERE org_id=$1 AND is_default)) RETURNING id`,
				st.OrgID, "Monitoring degraded: "+a.Name+" integration failing", sev, a.ID, key, a.Reason, st.Now).Scan(&incID)
			if err != nil {
				return err
			}
			if err := e.timeline(ctx, tx, st, incID, "opened", "Integration failing: "+a.Reason+
				". Affected resources show Unknown/Monitoring Degraded unless independent signals exist.", nil); err != nil {
				return err
			}
			if err := e.enqueueForIncident(ctx, tx, st, incID, "opened"); err != nil {
				return err
			}
		case failing && err == nil:
			if _, err := tx.Exec(ctx, `UPDATE incidents SET last_observed_at=$2 WHERE id=$1`, incID, st.Now); err != nil {
				return err
			}
		case !failing && err == nil:
			if err := e.resolveIncident(ctx, tx, st, incID, "Integration recovered: collection succeeding again"); err != nil {
				return err
			}
		}
	}
	return nil
}

func (e *Evaluator) timeline(ctx context.Context, tx pgx.Tx, st *orgState, incID, kind, msg string, data map[string]any) error {
	if data == nil {
		data = map[string]any{}
	}
	b, _ := json.Marshal(data)
	_, err := tx.Exec(ctx, `INSERT INTO incident_events(org_id, incident_id, at, kind, message, data) VALUES ($1,$2,$3,$4,$5,$6)`,
		st.OrgID, incID, st.Now, kind, msg, b)
	return err
}

// --- resource states ------------------------------------------------------------------

func (e *Evaluator) updateStates(ctx context.Context, tx pgx.Tx, st *orgState, points map[string]map[string]map[string][]aggPoint) error {
	// Firing alerts per resource.
	alerts := map[string][]health.AlertSummary{}
	ruleSev := map[string]ruleRow{}
	for _, r := range st.Rules {
		ruleSev[r.ID] = r
	}
	for _, in := range st.Instances {
		if in.State != alerting.StateFiring || in.ResourceID == nil {
			continue
		}
		r := ruleSev[in.Key.Rule]
		// Heartbeat/service/synthetic/provider evidence is represented natively in the
		// health signals; only metric and provider-state alerts are added as findings.
		if r.Kind != alerting.KindMetric && r.Kind != alerting.KindSynthetic {
			continue
		}
		alerts[*in.ResourceID] = append(alerts[*in.ResourceID], health.AlertSummary{Rule: r.Name, Severity: r.Severity, Summary: in.Summary})
	}
	svcIssues := map[string][]health.ServiceIssue{}
	for _, s := range st.Services {
		if s.Current != s.Expected && s.LastReported != nil && st.Now.Sub(*s.LastReported) <= 3*st.Policy.Interval+time.Minute {
			name := s.Name
			if s.Display != "" {
				name = s.Display
			}
			svcIssues[s.ResourceID] = append(svcIssues[s.ResourceID], health.ServiceIssue{Name: name, State: s.Current, Expected: s.Expected, Critical: s.Critical})
		}
	}
	checks := map[string][]health.CheckResult{}
	for _, c := range st.Synthetics {
		if c.ResourceID == "" || !c.Liveness || c.LastOK == nil || c.LastRun == nil {
			continue
		}
		checks[c.ResourceID] = append(checks[c.ResourceID], health.CheckResult{Name: c.Name, Kind: c.Kind, OK: *c.LastOK,
			Failures: c.Failures, Stale: st.Now.Sub(*c.LastRun) > 3*c.Interval+time.Minute})
	}

	for rid, r := range st.Resources {
		mwName, inMW := st.inMaintenance(r)
		degraded, degradedReason := st.accountDegraded(r)
		sig := health.Signals{
			Maintenance: inMW, MaintenanceName: mwName,
			PowerState: r.PowerState, ProviderHealth: r.ProviderHealth, ProviderReason: r.ProviderHealthReason,
			ProviderDataStale:   r.ProviderHealthAt == nil || st.Now.Sub(*r.ProviderHealthAt) > e.cfg.ProviderHealthStale,
			IntegrationDegraded: degraded, IntegrationDegradedReason: degradedReason,
			IngestDegraded: st.IngestDown,
			Checks:         checks[rid], Services: svcIssues[rid], Alerts: alerts[rid],
			HasMetrics: r.LastTelemetry != nil && st.Now.Sub(*r.LastTelemetry) <= e.cfg.StaleAfter,
		}
		if a, ok := st.Agents[rid]; ok {
			h := health.ClassifyHeartbeat(a.LastHeartbeat, st.Now, st.Policy, "skywatch-agent")
			sig.Agent = &h
		}
		if r.GuestHeartbeatAt != nil && !degraded {
			h := health.ClassifyHeartbeat(r.GuestHeartbeatAt, st.Now, st.Policy, r.GuestHeartbeatSource)
			sig.GuestHeartbeat = &h
		}
		res := health.Evaluate(sig)
		signals, _ := json.Marshal(map[string]any{
			"agent": sig.Agent, "guest_heartbeat": sig.GuestHeartbeat, "checks": sig.Checks, "services": sig.Services,
			"alerts": sig.Alerts, "integration_degraded": sig.IntegrationDegraded, "integration_reason": degradedReason,
			"ingest_degraded": sig.IngestDegraded, "provider_health_stale": sig.ProviderDataStale,
			"host_confirmed_down": res.HostConfirmedDown, "agent_problem": res.AgentProblem, "reasons": res.Reasons,
			"evaluated_at": st.Now,
		})
		if res.State != r.State {
			if _, err := tx.Exec(ctx, `UPDATE resource_state_history SET ended_at=$2 WHERE resource_id=$1 AND ended_at IS NULL`, rid, st.Now); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO resource_state_history(org_id, resource_id, state, reason, started_at) VALUES ($1,$2,$3,$4,$5)`,
				st.OrgID, rid, string(res.State), res.Reason, st.Now); err != nil {
				return err
			}
			r.StateSince = st.Now
		} else {
			// Make sure an open interval exists (first evaluation after migration).
			if _, err := tx.Exec(ctx, `INSERT INTO resource_state_history(org_id, resource_id, state, reason, started_at)
				SELECT $1,$2,$3,$4,$5 WHERE NOT EXISTS (SELECT 1 FROM resource_state_history WHERE resource_id=$2 AND ended_at IS NULL)`,
				st.OrgID, rid, string(res.State), res.Reason, r.StateSince); err != nil {
				return err
			}
		}
		var changes int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM resource_state_history WHERE resource_id=$1 AND started_at > $2`,
			rid, st.Now.Add(-st.FlapWindow)).Scan(&changes); err != nil {
			return err
		}
		flapping := changes >= st.FlapCount && st.FlapCount > 0
		reason := res.Reason
		if flapping {
			reason += " (flapping: " + fmt.Sprint(changes) + " state changes in " + st.FlapWindow.String() + ")"
		}
		if _, err := tx.Exec(ctx, `UPDATE resources SET operational_state=$2, state_reason=$3, state_since=$4, signals=$5, flapping=$6 WHERE id=$1`,
			rid, string(res.State), reason, r.StateSince, signals, flapping); err != nil {
			return err
		}
	}
	return nil
}
