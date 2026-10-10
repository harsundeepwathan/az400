package health

import (
	"strings"
	"testing"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
)

var now = time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)

func ago(d time.Duration) *time.Time { t := now.Add(-d); return &t }

func hb(d time.Duration) *Heartbeat {
	h := ClassifyHeartbeat(ago(d), now, DefaultHeartbeatPolicy, "agent")
	return &h
}

func TestClassifyHeartbeat(t *testing.T) {
	cases := []struct {
		age    time.Duration
		want   HeartbeatStatus
		missed int
	}{
		{30 * time.Second, HeartbeatOK, 0},
		{119 * time.Second, HeartbeatOK, 0},
		{2 * time.Minute, HeartbeatLate, 1},
		{4*time.Minute + 59*time.Second, HeartbeatLate, 3},
		{5 * time.Minute, HeartbeatMissing, 4},
		{time.Hour, HeartbeatMissing, 59},
	}
	for _, c := range cases {
		got := ClassifyHeartbeat(ago(c.age), now, DefaultHeartbeatPolicy, "agent")
		if got.Status != c.want || got.Missed != c.missed {
			t.Errorf("age %v: got %s/%d want %s/%d", c.age, got.Status, got.Missed, c.want, c.missed)
		}
	}
	if ClassifyHeartbeat(nil, now, DefaultHeartbeatPolicy, "agent").Status != HeartbeatNever {
		t.Error("nil heartbeat should be never")
	}
	future := now.Add(time.Minute)
	if ClassifyHeartbeat(&future, now, DefaultHeartbeatPolicy, "agent").Status != HeartbeatOK {
		t.Error("clock skew should not produce a missing heartbeat")
	}
}

func TestEvaluateDecisionTable(t *testing.T) {
	cases := []struct {
		name      string
		s         Signals
		want      model.OperationalState
		confirmed bool
		agentProb bool
		reason    string
	}{
		{name: "maintenance wins",
			s:    Signals{Maintenance: true, PowerState: model.PowerRunning, Agent: hb(time.Hour)},
			want: model.StateMaintenance},
		{name: "stopped by provider, missing heartbeat is expected",
			s:    Signals{PowerState: model.PowerDeallocated, Agent: hb(time.Hour)},
			want: model.StateStopped},
		{name: "stopped per stale discovery but agent fresh",
			s:    Signals{PowerState: model.PowerStopped, Agent: hb(10 * time.Second)},
			want: model.StateHealthy},
		{name: "running VM with no other signal is NOT healthy",
			s:    Signals{PowerState: model.PowerRunning},
			want: model.StateNoData},
		{name: "running + metrics but no agent is healthy with caveat",
			s:    Signals{PowerState: model.PowerRunning, HasMetrics: true},
			want: model.StateHealthy, reason: "OS responsiveness not verified"},
		{name: "missing heartbeat alone is critical, not down",
			s:    Signals{PowerState: model.PowerRunning, Agent: hb(10 * time.Minute)},
			want: model.StateCritical, reason: "host status unconfirmed"},
		{name: "missing heartbeat + failing checks is confirmed down",
			s: Signals{PowerState: model.PowerRunning, Agent: hb(10 * time.Minute),
				Checks: []CheckResult{{Name: "ping", OK: false, Failures: 3}, {Name: "ssh:22", OK: false}}},
			want: model.StateDown, confirmed: true},
		{name: "missing heartbeat + passing checks is agent problem",
			s: Signals{PowerState: model.PowerRunning, Agent: hb(10 * time.Minute),
				Checks: []CheckResult{{Name: "https", OK: true}}},
			want: model.StateCritical, agentProb: true, reason: "monitoring agent problem"},
		{name: "provider unavailable is down",
			s:    Signals{PowerState: model.PowerRunning, ProviderHealth: model.HealthUnavailable, ProviderReason: "host failure"},
			want: model.StateDown, confirmed: true},
		{name: "provider unavailable ignored when integration degraded",
			s: Signals{PowerState: model.PowerRunning, ProviderHealth: model.HealthUnavailable,
				IntegrationDegraded: true, IntegrationDegradedReason: "HTTP 429 throttled"},
			want: model.StateUnknown, reason: "Monitoring degraded"},
		{name: "integration degraded but agent fresh stays healthy",
			s:    Signals{PowerState: model.PowerRunning, IntegrationDegraded: true, Agent: hb(20 * time.Second)},
			want: model.StateHealthy},
		{name: "ingest degraded: missing heartbeats are not evidence",
			s:    Signals{PowerState: model.PowerRunning, IngestDegraded: true, Agent: hb(20 * time.Minute)},
			want: model.StateUnknown},
		{name: "late heartbeat is warning",
			s:    Signals{PowerState: model.PowerRunning, Agent: hb(3 * time.Minute)},
			want: model.StateWarning},
		{name: "guest heartbeat from provider rescues missing agent",
			s: Signals{PowerState: model.PowerRunning, Agent: hb(30 * time.Minute),
				GuestHeartbeat: &Heartbeat{Status: HeartbeatOK, Source: "ama"}},
			want: model.StateHealthy},
		{name: "critical service stopped",
			s: Signals{PowerState: model.PowerRunning, Agent: hb(time.Second),
				Services: []ServiceIssue{{Name: "nginx", State: "inactive", Expected: "running", Critical: true}}},
			want: model.StateCritical, reason: "nginx"},
		{name: "critical alert beats warning service",
			s: Signals{PowerState: model.PowerRunning, Agent: hb(time.Second),
				Services: []ServiceIssue{{Name: "cron", State: "failed", Expected: "running"}},
				Alerts:   []AlertSummary{{Severity: model.SeverityCritical, Summary: "Disk / at 93%"}}},
			want: model.StateCritical, reason: "Disk / at 93%"},
		{name: "agent enrolled never reported",
			s:    Signals{PowerState: model.PowerRunning, Agent: &Heartbeat{Status: HeartbeatNever}},
			want: model.StateNoData},
		{name: "load balancer with provider health only",
			s:    Signals{PowerState: model.PowerNotApplicable, ProviderHealth: model.HealthAvailable},
			want: model.StateHealthy},
		{name: "stale provider health is not trusted",
			s:    Signals{PowerState: model.PowerNotApplicable, ProviderHealth: model.HealthAvailable, ProviderDataStale: true},
			want: model.StateNoData},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Evaluate(c.s)
			if got.State != c.want {
				t.Fatalf("state = %s (%s), want %s", got.State, got.Reason, c.want)
			}
			if got.HostConfirmedDown != c.confirmed {
				t.Errorf("HostConfirmedDown = %v", got.HostConfirmedDown)
			}
			if got.AgentProblem != c.agentProb {
				t.Errorf("AgentProblem = %v", got.AgentProblem)
			}
			if c.reason != "" && !strings.Contains(got.Reason, c.reason) {
				t.Errorf("reason %q does not contain %q", got.Reason, c.reason)
			}
		})
	}
}

func TestIsFlapping(t *testing.T) {
	ch := []time.Time{now.Add(-1 * time.Minute), now.Add(-3 * time.Minute), now.Add(-5 * time.Minute), now.Add(-30 * time.Minute)}
	if !IsFlapping(ch, now, 15*time.Minute, 3) {
		t.Error("3 changes in 15m should flap")
	}
	if IsFlapping(ch, now, 15*time.Minute, 4) {
		t.Error("only 3 changes inside the window")
	}
}

func TestComputeAvailability(t *testing.T) {
	from := now.Add(-10 * time.Hour)
	ivs := []Interval{
		{State: model.StateNoData, Start: from, End: from.Add(time.Hour)},
		{State: model.StateHealthy, Start: from.Add(time.Hour), End: from.Add(5 * time.Hour)},
		{State: model.StateDown, Start: from.Add(5 * time.Hour), End: from.Add(6 * time.Hour)},
		{State: model.StateMaintenance, Start: from.Add(6 * time.Hour), End: from.Add(7 * time.Hour)},
		{State: model.StateCritical, Start: from.Add(7 * time.Hour), End: from.Add(8 * time.Hour)},
		{State: model.StateHealthy, Start: from.Add(8 * time.Hour)}, // open
	}
	a := ComputeAvailability(ivs, from, now, AvailabilityPolicy{})
	// available: 4h healthy + 1h critical + 2h healthy = 7h; unavailable: 1h
	if a.Available != 7*time.Hour || a.Unavailable != time.Hour || a.Excluded != 2*time.Hour {
		t.Fatalf("got %+v", a)
	}
	if *a.Percent != 87.5 {
		t.Errorf("percent = %v", *a.Percent)
	}
	strict := ComputeAvailability(ivs, from, now, AvailabilityPolicy{CriticalIsDown: true})
	if *strict.Percent != 75 {
		t.Errorf("strict percent = %v", *strict.Percent)
	}
	empty := ComputeAvailability(nil, from, now, AvailabilityPolicy{})
	if empty.Percent != nil || empty.Excluded != 10*time.Hour {
		t.Errorf("no observations must not yield a percentage: %+v", empty)
	}
}
