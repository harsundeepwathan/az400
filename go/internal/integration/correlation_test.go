package integration

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/tsdb"
)

// TestStormControlAndNotifications: five VMs in one account/region breach the disk
// rule at once. One parent incident notifies; children are grouped and silent.
// Recovery resolves children, then the parent, and a resolve notification is queued.
func TestStormControlAndNotifications(t *testing.T) {
	h := setup(t)
	ctx := context.Background()
	var acct, channel string
	must(t, h.pool.QueryRow(ctx, `INSERT INTO cloud_accounts(org_id, provider, name, auth_method, status, last_success_at)
		VALUES ($1,'azure','Prod','client_secret','active',now()) RETURNING id`, h.orgID).Scan(&acct))
	must(t, h.pool.QueryRow(ctx, `INSERT INTO notification_channels(org_id, kind, name, config) VALUES ($1,'webhook','ops','{}') RETURNING id`,
		h.orgID).Scan(&channel))
	exec(t, h.pool, `UPDATE escalation_policies SET steps=$2 WHERE org_id=$1 AND is_default`, h.orgID,
		fmt.Sprintf(`[{"delay_seconds":0,"channel_ids":["%s"]},{"delay_seconds":900,"channel_ids":["%s"]}]`, channel, channel))

	now := time.Now().UTC().Truncate(time.Minute)
	h.now = now.Add(30 * time.Second)
	var ids []string
	for i := 0; i < 5; i++ {
		var id string
		must(t, h.pool.QueryRow(ctx, `INSERT INTO resources(org_id, cloud_account_id, provider, provider_resource_id, name, resource_type, region, power_state, provider_health, provider_health_at)
			VALUES ($1,$2,'azure',$3,$4,'vm','westeurope','running','available',now()) RETURNING id`,
			h.orgID, acct, fmt.Sprintf("/vm/%d", i), fmt.Sprintf("vm-%d", i)).Scan(&id))
		ids = append(ids, id)
		if _, err := tsdb.WriteSamples(ctx, h.pool, h.orgID, id, "azure_monitor",
			[]model.Sample{{Metric: "disk.utilization", Series: "mount=/", TS: now, Value: 95}}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	h.cycle()

	var parents, children, deliveries int
	must(t, h.pool.QueryRow(ctx, `SELECT count(*) FROM incidents WHERE org_id=$1 AND dedup_key LIKE 'burst:%'`, h.orgID).Scan(&parents))
	must(t, h.pool.QueryRow(ctx, `SELECT count(*) FROM incidents WHERE org_id=$1 AND parent_incident_id IS NOT NULL`, h.orgID).Scan(&children))
	if parents != 1 || children != 5 {
		t.Fatalf("expected 1 parent and 5 grouped children, got %d/%d", parents, children)
	}
	// Notifications: the first two incidents opened before the burst threshold was reached
	// notify individually; after grouping only the parent notifies.
	must(t, h.pool.QueryRow(ctx, `SELECT count(*) FROM notification_deliveries WHERE org_id=$1 AND event='opened'`, h.orgID).Scan(&deliveries))
	if deliveries != 3 {
		t.Fatalf("expected 3 opened notifications (2 before grouping + parent), got %d", deliveries)
	}

	// Escalation step 2 after 15 minutes unacknowledged.
	h.now = h.now.Add(16 * time.Minute)
	for _, id := range ids { // keep the condition true
		_, _ = tsdb.WriteSamples(ctx, h.pool, h.orgID, id, "azure_monitor",
			[]model.Sample{{Metric: "disk.utilization", Series: "mount=/", TS: h.now.Add(-10 * time.Second), Value: 95}}, time.Now().Add(20*time.Minute))
	}
	h.cycle()
	var escalated int
	must(t, h.pool.QueryRow(ctx, `SELECT count(*) FROM notification_deliveries WHERE org_id=$1 AND event='escalated'`, h.orgID).Scan(&escalated))
	if escalated == 0 {
		t.Fatal("unacknowledged incident should escalate after the step delay")
	}

	// Recovery.
	h.now = h.now.Add(time.Minute)
	for _, id := range ids {
		_, _ = tsdb.WriteSamples(ctx, h.pool, h.orgID, id, "azure_monitor",
			[]model.Sample{{Metric: "disk.utilization", Series: "mount=/", TS: h.now.Add(-5 * time.Second), Value: 40}}, time.Now().Add(20*time.Minute))
	}
	h.cycle()
	var open, resolvedNotes int
	must(t, h.pool.QueryRow(ctx, `SELECT count(*) FROM incidents WHERE org_id=$1 AND status <> 'resolved'`, h.orgID).Scan(&open))
	must(t, h.pool.QueryRow(ctx, `SELECT count(*) FROM notification_deliveries WHERE org_id=$1 AND event='resolved'`, h.orgID).Scan(&resolvedNotes))
	if open != 0 || resolvedNotes == 0 {
		t.Fatalf("all incidents should resolve with a recovery notification: open=%d resolved-notes=%d", open, resolvedNotes)
	}
}

// TestIntegrationFailureDoesNotMarkResourcesDown: an account with auth failure makes
// provider-only resources Unknown and raises one monitoring-degraded incident.
func TestIntegrationFailureDoesNotMarkResourcesDown(t *testing.T) {
	h := setup(t)
	ctx := context.Background()
	var acct, res string
	must(t, h.pool.QueryRow(ctx, `INSERT INTO cloud_accounts(org_id, provider, name, auth_method, status, status_reason, last_success_at)
		VALUES ($1,'azure','Prod','client_secret','error','Authentication failed: AADSTS7000215 invalid client secret', now() - interval '1 hour') RETURNING id`,
		h.orgID).Scan(&acct))
	must(t, h.pool.QueryRow(ctx, `INSERT INTO resources(org_id, cloud_account_id, provider, provider_resource_id, name, resource_type, power_state, provider_health, provider_health_at)
		VALUES ($1,$2,'azure','/vm/x','vm-x','vm','running','unavailable',now() - interval '1 hour') RETURNING id`, h.orgID, acct).Scan(&res))
	h.cycle()
	var st, reason string
	must(t, h.pool.QueryRow(ctx, `SELECT operational_state, state_reason FROM resources WHERE id=$1`, res).Scan(&st, &reason))
	if st != "unknown" {
		t.Fatalf("expected unknown (monitoring degraded), got %s: %s", st, reason)
	}
	var title, sev string
	must(t, h.pool.QueryRow(ctx, `SELECT title, severity FROM incidents WHERE org_id=$1 AND dedup_key=$2`, h.orgID, "account:"+acct).Scan(&title, &sev))
	if sev != "critical" {
		t.Errorf("auth failure should be critical: %s", sev)
	}
	exec(t, h.pool, `UPDATE cloud_accounts SET status='active', status_reason=NULL, last_success_at=now() WHERE id=$1`, acct)
	h.cycle()
	var status string
	must(t, h.pool.QueryRow(ctx, `SELECT status FROM incidents WHERE org_id=$1 AND dedup_key=$2`, h.orgID, "account:"+acct).Scan(&status))
	if status != "resolved" {
		t.Fatalf("integration incident should resolve on recovery: %s", status)
	}
}
