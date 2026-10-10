package evaluator

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

type escalationStep struct {
	DelaySeconds int      `json:"delay_seconds"`
	ChannelIDs   []string `json:"channel_ids"`
}

type incidentView struct {
	ID, Title, Severity, Status, Trigger, Dedup string
	Number                                      int64
	ParentID, PolicyID                          *string
	FirstDetected, LastObserved                 time.Time
	ResolvedAt, LastNotified                    *time.Time
	Step                                        int
	ResourceName, Provider, Region, RType       *string
	Steps                                       []escalationStep
	Repeat                                      *int
	NotifyOnResolve                             bool
}

func (e *Evaluator) loadIncident(ctx context.Context, tx pgx.Tx, id string) (*incidentView, error) {
	v := &incidentView{NotifyOnResolve: true}
	var steps []byte
	err := tx.QueryRow(ctx, `SELECT i.id, i.number, i.title, i.severity, i.status, i.trigger_summary, i.dedup_key, i.parent_incident_id,
			i.escalation_policy_id, i.first_detected_at, i.last_observed_at, i.resolved_at, i.last_notified_at, i.escalation_step,
			r.name, r.provider, r.region, r.resource_type, coalesce(p.steps,'[]'), p.repeat_interval_s, coalesce(p.notify_on_resolve, true)
		FROM incidents i LEFT JOIN resources r ON r.id=i.resource_id LEFT JOIN escalation_policies p ON p.id=i.escalation_policy_id
		WHERE i.id=$1`, id).Scan(&v.ID, &v.Number, &v.Title, &v.Severity, &v.Status, &v.Trigger, &v.Dedup, &v.ParentID, &v.PolicyID,
		&v.FirstDetected, &v.LastObserved, &v.ResolvedAt, &v.LastNotified, &v.Step, &v.ResourceName, &v.Provider, &v.Region, &v.RType,
		&steps, &v.Repeat, &v.NotifyOnResolve)
	if err != nil {
		return nil, err
	}
	_ = json.Unmarshal(steps, &v.Steps)
	return v, nil
}

// payload is the provider-neutral notification document rendered by each channel.
func payload(v *incidentView, event string, orgID string, now time.Time) map[string]any {
	inc := map[string]any{
		"id": v.ID, "number": v.Number, "title": v.Title, "severity": v.Severity, "status": v.Status,
		"trigger_summary": v.Trigger, "first_detected_at": v.FirstDetected, "last_observed_at": v.LastObserved,
	}
	if v.ResolvedAt != nil {
		inc["resolved_at"] = v.ResolvedAt
		inc["duration_seconds"] = int(v.ResolvedAt.Sub(v.FirstDetected).Seconds())
	}
	if v.ResourceName != nil {
		inc["resource"] = map[string]any{"name": deref(v.ResourceName), "provider": deref(v.Provider), "region": deref(v.Region), "type": deref(v.RType)}
	}
	return map[string]any{"event": event, "org_id": orgID, "generated_at": now, "incident": inc}
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// enqueueForIncident schedules notifications for an incident lifecycle event.
func (e *Evaluator) enqueueForIncident(ctx context.Context, tx pgx.Tx, st *orgState, incID, event string) error {
	v, err := e.loadIncident(ctx, tx, incID)
	if err != nil {
		return err
	}
	if v.ParentID != nil {
		return nil // grouped under a parent incident, which carries the notifications
	}
	switch event {
	case "opened", "reopened":
		// Notify every step whose delay has already elapsed (normally step 0).
		step := 0
		for step < len(v.Steps) && !v.FirstDetected.Add(secs(v.Steps[step].DelaySeconds)).After(st.Now) {
			if err := e.deliver(ctx, tx, st, v, fmt.Sprintf("%s:%d", event, step), v.Steps[step].ChannelIDs, event); err != nil {
				return err
			}
			step++
		}
		_, err = tx.Exec(ctx, `UPDATE incidents SET escalation_step=$2, last_notified_at=$3 WHERE id=$1`, incID, step, st.Now)
		return err
	case "severity_raised":
		return e.deliver(ctx, tx, st, v, "severity:"+v.Severity, reachedChannels(v), event)
	case "resolved":
		if !v.NotifyOnResolve {
			return nil
		}
		return e.deliver(ctx, tx, st, v, "resolved:"+v.ResolvedAt.UTC().Format(time.RFC3339), reachedChannels(v), event)
	}
	return nil
}

func reachedChannels(v *incidentView) []string {
	set := map[string]bool{}
	var out []string
	for i := 0; i < v.Step && i < len(v.Steps); i++ {
		for _, c := range v.Steps[i].ChannelIDs {
			if !set[c] {
				set[c] = true
				out = append(out, c)
			}
		}
	}
	return out
}

func (e *Evaluator) deliver(ctx context.Context, tx pgx.Tx, st *orgState, v *incidentView, discriminator string, channels []string, event string) error {
	if len(channels) == 0 {
		return nil
	}
	b, _ := json.Marshal(payload(v, event, st.OrgID, st.Now))
	for _, ch := range channels {
		_, err := tx.Exec(ctx, `INSERT INTO notification_deliveries(org_id, incident_id, channel_id, event, dedup_key, payload)
			SELECT $1,$2,c.id,$3,$4,$5 FROM notification_channels c WHERE c.id=$6 AND c.org_id=$1 AND c.enabled
			ON CONFLICT (dedup_key) DO NOTHING`,
			st.OrgID, v.ID, event, fmt.Sprintf("inc:%s:%s:%s", v.ID, discriminator, ch), b, ch)
		if err != nil {
			return err
		}
	}
	return nil
}

// escalate advances escalation steps and repeat notifications for unacknowledged
// incidents.
func (e *Evaluator) escalate(ctx context.Context, tx pgx.Tx, st *orgState) error {
	rows, err := tx.Query(ctx, `SELECT id FROM incidents WHERE org_id=$1 AND status='open' AND parent_incident_id IS NULL
		AND escalation_policy_id IS NOT NULL`, st.OrgID)
	if err != nil {
		return err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	rows.Close()
	for _, id := range ids {
		v, err := e.loadIncident(ctx, tx, id)
		if err != nil {
			return err
		}
		step := v.Step
		notified := false
		for step < len(v.Steps) && !v.FirstDetected.Add(secs(v.Steps[step].DelaySeconds)).After(st.Now) {
			if err := e.deliver(ctx, tx, st, v, fmt.Sprintf("escalation:%d", step), v.Steps[step].ChannelIDs, "escalated"); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `INSERT INTO incident_events(org_id, incident_id, at, kind, message) VALUES ($1,$2,$3,'escalated',$4)`,
				st.OrgID, id, st.Now, fmt.Sprintf("Escalated to step %d (unacknowledged after %s)", step+1, secs(v.Steps[step].DelaySeconds))); err != nil {
				return err
			}
			step++
			notified = true
		}
		if !notified && v.Repeat != nil && *v.Repeat > 0 && v.LastNotified != nil &&
			!v.LastNotified.Add(secs(*v.Repeat)).After(st.Now) && v.Step > 0 {
			n := int(st.Now.Sub(v.FirstDetected) / secs(*v.Repeat))
			if err := e.deliver(ctx, tx, st, v, fmt.Sprintf("repeat:%d", n), reachedChannels(v), "repeat"); err != nil {
				return err
			}
			notified = true
		}
		if notified {
			if _, err := tx.Exec(ctx, `UPDATE incidents SET escalation_step=$2, last_notified_at=$3 WHERE id=$1`, id, step, st.Now); err != nil {
				return err
			}
		}
	}
	return nil
}
