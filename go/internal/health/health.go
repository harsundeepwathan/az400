// Package health turns independent monitoring signals into an operational state.
//
// The rules are deliberately conservative:
//   - "VM running" (provider power state) is never treated as "OS responsive".
//   - A missing agent heartbeat alone never yields Down: it yields Critical with an
//     explicit "host status unconfirmed" reason. Down requires corroboration from an
//     independent signal (failing reachability checks, or the provider reporting the
//     resource Unavailable).
//   - When the evidence is insufficient (no signals, or the collection path is failing)
//     the state is NoData or Unknown, never Healthy.
//
// See docs/STATE_MODEL.md for the full decision table.
package health

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
)

// HeartbeatPolicy configures heartbeat classification. Defaults: 60s interval, warning
// after 2 minutes, critical after 5 minutes.
type HeartbeatPolicy struct {
	Interval time.Duration
	Warning  time.Duration
	Critical time.Duration
}

// DefaultHeartbeatPolicy is the initial policy described in the product requirements.
var DefaultHeartbeatPolicy = HeartbeatPolicy{Interval: time.Minute, Warning: 2 * time.Minute, Critical: 5 * time.Minute}

// HeartbeatStatus classifies heartbeat freshness.
type HeartbeatStatus string

const (
	HeartbeatNone    HeartbeatStatus = "none"    // no heartbeat source for this resource
	HeartbeatNever   HeartbeatStatus = "never"   // source exists, nothing received yet
	HeartbeatOK      HeartbeatStatus = "ok"      // < warning
	HeartbeatLate    HeartbeatStatus = "late"    // warning .. critical
	HeartbeatMissing HeartbeatStatus = "missing" // > critical
)

// Heartbeat describes one heartbeat source evaluation.
type Heartbeat struct {
	Status HeartbeatStatus `json:"status"`
	Last   *time.Time      `json:"last,omitempty"`
	Age    time.Duration   `json:"age_ns,omitempty"`
	Missed int             `json:"missed"`
	Source string          `json:"source"`
}

// ClassifyHeartbeat classifies the last heartbeat time against a policy.
func ClassifyHeartbeat(last *time.Time, now time.Time, p HeartbeatPolicy, source string) Heartbeat {
	if p.Interval <= 0 {
		p = DefaultHeartbeatPolicy
	}
	h := Heartbeat{Source: source, Last: last}
	if last == nil {
		h.Status = HeartbeatNever
		return h
	}
	h.Age = now.Sub(*last)
	if h.Age < 0 {
		h.Age = 0 // clock skew: a heartbeat "from the future" counts as fresh
	}
	if missed := int(h.Age/p.Interval) - 1; missed > 0 {
		h.Missed = missed
	}
	switch {
	case h.Age >= p.Critical:
		h.Status = HeartbeatMissing
	case h.Age >= p.Warning:
		h.Status = HeartbeatLate
	default:
		h.Status = HeartbeatOK
	}
	return h
}

// CheckResult is the latest result of an independent reachability check (ICMP, TCP,
// HTTP) linked to the resource.
type CheckResult struct {
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	OK       bool   `json:"ok"`
	Failures int    `json:"consecutive_failures"`
	Stale    bool   `json:"stale"`
}

// ServiceIssue is a required OS service that is not in its expected state.
type ServiceIssue struct {
	Name     string `json:"name"`
	State    string `json:"state"`
	Expected string `json:"expected"`
	Critical bool   `json:"critical"`
}

// AlertSummary is a currently firing alert on the resource.
type AlertSummary struct {
	Rule     string         `json:"rule"`
	Severity model.Severity `json:"severity"`
	Summary  string         `json:"summary"`
}

// Signals is all evidence about one resource at evaluation time.
type Signals struct {
	Maintenance       bool
	MaintenanceName   string
	PowerState        model.PowerState
	ProviderHealth    model.ProviderHealth
	ProviderReason    string
	ProviderDataStale bool // last successful provider collection is too old
	// IntegrationDegraded is set when the account's collector is failing (auth errors,
	// throttling, API outage). Provider-derived signals must then not be trusted.
	IntegrationDegraded       bool
	IntegrationDegradedReason string
	// IngestDegraded is set when the platform's own agent ingestion path is unhealthy,
	// in which case missing agent heartbeats are not evidence of a host problem.
	IngestDegraded bool
	Agent          *Heartbeat // nil when no Skywatch agent is enrolled for the resource
	GuestHeartbeat *Heartbeat // provider-side guest heartbeat (e.g. Azure Monitor Agent)
	Checks         []CheckResult
	Services       []ServiceIssue
	Alerts         []AlertSummary
	HasMetrics     bool // any recent metric sample from any source
}

// Result is the evaluated operational state.
type Result struct {
	State   model.OperationalState `json:"state"`
	Reason  string                 `json:"reason"`
	Reasons []string               `json:"reasons,omitempty"`
	// HostConfirmedDown is true only when independent signals agree the host is down.
	HostConfirmedDown bool `json:"host_confirmed_down"`
	// AgentProblem is true when the agent is silent but other evidence shows the host up.
	AgentProblem bool `json:"agent_problem"`
}

type finding struct {
	rank   int // higher is worse
	state  model.OperationalState
	reason string
}

var stateRank = map[model.OperationalState]int{
	model.StateHealthy:  1,
	model.StateWarning:  2,
	model.StateCritical: 3,
	model.StateDown:     4,
}

// Evaluate combines signals into an operational state.
func Evaluate(s Signals) Result {
	if s.Maintenance {
		r := "In maintenance window"
		if s.MaintenanceName != "" {
			r += ": " + s.MaintenanceName
		}
		return Result{State: model.StateMaintenance, Reason: r}
	}
	// A fresh heartbeat beats a power state from the last discovery run: the resource was
	// started after discovery last looked at it.
	freshHB := (s.Agent != nil && s.Agent.Status == HeartbeatOK) || (s.GuestHeartbeat != nil && s.GuestHeartbeat.Status == HeartbeatOK)
	if s.PowerState.IsOff() && !s.IntegrationDegraded && !freshHB {
		return Result{State: model.StateStopped, Reason: "Provider reports the resource is " + string(s.PowerState)}
	}

	var fs []finding
	add := func(st model.OperationalState, format string, args ...any) {
		fs = append(fs, finding{rank: stateRank[st], state: st, reason: fmt.Sprintf(format, args...)})
	}

	// --- liveness evidence -----------------------------------------------------------
	hb := bestHeartbeat(s.Agent, s.GuestHeartbeat)
	var activeChecks, okChecks, failingChecks int
	var failingNames []string
	for _, c := range s.Checks {
		if c.Stale {
			continue
		}
		activeChecks++
		if c.OK {
			okChecks++
		} else {
			failingChecks++
			failingNames = append(failingNames, c.Name)
		}
	}
	allChecksFailing := activeChecks > 0 && failingChecks == activeChecks
	providerUnavailable := s.ProviderHealth == model.HealthUnavailable && !s.IntegrationDegraded && !s.ProviderDataStale

	res := Result{}
	heartbeatMissing := hb != nil && hb.Status == HeartbeatMissing && !s.IngestDegraded

	switch {
	case providerUnavailable:
		res.HostConfirmedDown = true
		add(model.StateDown, "Provider reports the resource unavailable%s", suffix(s.ProviderReason))
	case heartbeatMissing && allChecksFailing:
		res.HostConfirmedDown = true
		add(model.StateDown, "No heartbeat for %s and all reachability checks failing (%s)", round(hb.Age), strings.Join(failingNames, ", "))
	case heartbeatMissing && okChecks > 0:
		res.AgentProblem = true
		add(model.StateCritical, "Agent not reporting for %s, but the host answers reachability checks: monitoring agent problem", round(hb.Age))
	case heartbeatMissing:
		add(model.StateCritical, "No heartbeat for %s; host status unconfirmed (no independent reachability check)", round(hb.Age))
	case hb != nil && hb.Status == HeartbeatLate && !s.IngestDegraded:
		add(model.StateWarning, "Heartbeat late (%s since last)", round(hb.Age))
	}
	if !res.HostConfirmedDown && failingChecks > 0 {
		if allChecksFailing && hb == nil {
			add(model.StateCritical, "All reachability checks failing: %s", strings.Join(failingNames, ", "))
		} else if !heartbeatMissing {
			add(model.StateWarning, "Reachability check failing: %s", strings.Join(failingNames, ", "))
		}
	}
	if s.ProviderHealth == model.HealthDegraded && !s.IntegrationDegraded {
		add(model.StateWarning, "Provider reports degraded health%s", suffix(s.ProviderReason))
	}
	switch s.PowerState {
	case model.PowerStarting, model.PowerStopping, model.PowerProvisioning:
		add(model.StateWarning, "Resource is %s", s.PowerState)
	case model.PowerDeleting:
		add(model.StateWarning, "Resource is being deleted")
	}

	// --- workload evidence -----------------------------------------------------------
	for _, svc := range s.Services {
		st := model.StateWarning
		if svc.Critical {
			st = model.StateCritical
		}
		add(st, "Service %s is %s (expected %s)", svc.Name, svc.State, svc.Expected)
	}
	for _, a := range s.Alerts {
		st := model.StateWarning
		if a.Severity == model.SeverityCritical {
			st = model.StateCritical
		}
		add(st, "%s", a.Summary)
	}

	if len(fs) > 0 {
		sort.SliceStable(fs, func(i, j int) bool { return fs[i].rank > fs[j].rank })
		res.State = fs[0].state
		res.Reason = fs[0].reason
		for _, f := range fs {
			res.Reasons = append(res.Reasons, f.reason)
		}
		return res
	}

	// --- no findings: decide between healthy, unknown and no data ---------------------
	positive := (hb != nil && hb.Status == HeartbeatOK) || okChecks > 0 ||
		(s.ProviderHealth == model.HealthAvailable && !s.IntegrationDegraded && !s.ProviderDataStale) ||
		(s.HasMetrics && !s.IntegrationDegraded)
	if s.IntegrationDegraded && !positive {
		return Result{State: model.StateUnknown, Reason: "Monitoring degraded: " + nonEmpty(s.IntegrationDegradedReason, "provider integration failing")}
	}
	if !positive {
		if hb != nil && hb.Status == HeartbeatNever {
			return Result{State: model.StateNoData, Reason: "Agent enrolled but no heartbeat received yet"}
		}
		if s.IngestDegraded && hb != nil {
			return Result{State: model.StateUnknown, Reason: "Monitoring degraded: agent ingestion pipeline unhealthy"}
		}
		return Result{State: model.StateNoData, Reason: "No monitoring signal available (no agent, health or metric data)"}
	}
	r := "All signals healthy"
	if hb == nil && s.PowerState == model.PowerRunning {
		r = "Provider signals healthy (no guest agent: OS responsiveness not verified)"
	}
	return Result{State: model.StateHealthy, Reason: r}
}

// bestHeartbeat returns the freshest heartbeat among sources, or nil when there is no
// heartbeat source at all.
func bestHeartbeat(hs ...*Heartbeat) *Heartbeat {
	var best *Heartbeat
	for _, h := range hs {
		if h == nil || h.Status == HeartbeatNone {
			continue
		}
		if best == nil || heartbeatRank(h.Status) < heartbeatRank(best.Status) {
			best = h
		}
	}
	return best
}

func heartbeatRank(s HeartbeatStatus) int {
	switch s {
	case HeartbeatOK:
		return 0
	case HeartbeatLate:
		return 1
	case HeartbeatMissing:
		return 2
	default:
		return 3
	}
}

func suffix(s string) string {
	if s == "" {
		return ""
	}
	return ": " + s
}

func nonEmpty(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func round(d time.Duration) time.Duration {
	if d > time.Minute {
		return d.Round(time.Minute)
	}
	return d.Round(time.Second)
}

// IsFlapping reports whether the number of state changes within window exceeds threshold.
func IsFlapping(changes []time.Time, now time.Time, window time.Duration, threshold int) bool {
	if threshold <= 0 {
		return false
	}
	n := 0
	for _, t := range changes {
		if now.Sub(t) <= window {
			n++
		}
	}
	return n >= threshold
}
