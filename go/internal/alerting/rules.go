// Package alerting contains the pure alert-evaluation logic: scope matching, threshold
// evaluation over time series, and the alert instance state machine
// (normal → pending → firing → resolved). Persistence lives in package evaluator.
package alerting

import (
	"fmt"
	"math"
	"sort"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
)

// Kind of alert rule.
type Kind string

const (
	KindMetric        Kind = "metric_threshold"
	KindHeartbeat     Kind = "heartbeat"
	KindServiceState  Kind = "service_state"
	KindSynthetic     Kind = "synthetic"
	KindProviderState Kind = "provider_state"
)

// Scope selects the resources a rule applies to. Empty fields match everything.
type Scope struct {
	Providers     []string          `json:"providers,omitempty"`
	ResourceTypes []string          `json:"resource_types,omitempty"`
	Environments  []string          `json:"environments,omitempty"`
	OSTypes       []string          `json:"os_types,omitempty"`
	Regions       []string          `json:"regions,omitempty"`
	AccountIDs    []string          `json:"account_ids,omitempty"`
	ResourceIDs   []string          `json:"resource_ids,omitempty"`
	Tags          map[string]string `json:"tags,omitempty"`
}

// Exclusions remove resources or series from a rule (e.g. a scratch volume).
type Exclusions struct {
	ResourceIDs  []string          `json:"resource_ids,omitempty"`
	Series       []string          `json:"series,omitempty"` // globs, e.g. "mount=/mnt/scratch*"
	Environments []string          `json:"environments,omitempty"`
	OSTypes      []string          `json:"os_types,omitempty"`
	Tags         map[string]string `json:"tags,omitempty"`
}

// Rule is an alert rule definition.
type Rule struct {
	ID                string
	Name              string
	Kind              Kind
	Metric            string
	SeriesMatch       string // glob, empty = all series
	Aggregation       string // avg|min|max|last per evaluation bucket
	Operator          string // > >= < <=
	Threshold         float64
	RecoveryThreshold *float64
	For               time.Duration
	Consecutive       int
	Severity          model.Severity
	Scope             Scope
	Exclusions        Exclusions
}

// Subject is the resource attributes used for scope matching.
type Subject struct {
	ID          string
	Provider    string
	Type        string
	Environment string
	OSType      string
	Region      string
	AccountID   string
	Tags        map[string]string
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func tagsMatch(want, have map[string]string) bool {
	for k, v := range want {
		hv, ok := have[k]
		if !ok || (v != "" && v != "*" && hv != v) {
			return false
		}
	}
	return true
}

// Matches reports whether the scope selects the subject. An empty scope matches all.
func (sc Scope) Matches(s Subject) bool {
	return !(len(sc.Providers) > 0 && !contains(sc.Providers, s.Provider) ||
		len(sc.ResourceTypes) > 0 && !contains(sc.ResourceTypes, s.Type) ||
		len(sc.Environments) > 0 && !contains(sc.Environments, s.Environment) ||
		len(sc.OSTypes) > 0 && !contains(sc.OSTypes, s.OSType) ||
		len(sc.Regions) > 0 && !contains(sc.Regions, s.Region) ||
		len(sc.AccountIDs) > 0 && !contains(sc.AccountIDs, s.AccountID) ||
		len(sc.ResourceIDs) > 0 && !contains(sc.ResourceIDs, s.ID) ||
		len(sc.Tags) > 0 && !tagsMatch(sc.Tags, s.Tags))
}

// Matches reports whether the rule applies to the subject.
func (r Rule) Matches(s Subject) bool {
	if !r.Scope.Matches(s) {
		return false
	}
	ex := r.Exclusions
	if contains(ex.ResourceIDs, s.ID) || contains(ex.Environments, s.Environment) || contains(ex.OSTypes, s.OSType) {
		return false
	}
	if len(ex.Tags) > 0 && tagsMatch(ex.Tags, s.Tags) {
		return false
	}
	return true
}

// SeriesIncluded reports whether a series key passes SeriesMatch and exclusions.
func (r Rule) SeriesIncluded(series string) bool {
	if r.SeriesMatch != "" && !Glob(r.SeriesMatch, series) {
		return false
	}
	for _, g := range r.Exclusions.Series {
		if Glob(g, series) {
			return false
		}
	}
	return true
}

// Glob matches s against a pattern where '*' matches any run of characters (including
// '/', so "mount=*" matches "mount=/var/log") and '?' matches one character.
func Glob(pattern, s string) bool {
	if pattern == "" {
		return s == ""
	}
	switch pattern[0] {
	case '*':
		for i := 0; i <= len(s); i++ {
			if Glob(pattern[1:], s[i:]) {
				return true
			}
		}
		return false
	case '?':
		return s != "" && Glob(pattern[1:], s[1:])
	default:
		return s != "" && s[0] == pattern[0] && Glob(pattern[1:], s[1:])
	}
}

// Breaches applies the rule operator to v against threshold t.
func Breaches(op string, v, t float64) bool {
	switch op {
	case ">":
		return v > t
	case ">=":
		return v >= t
	case "<":
		return v < t
	case "<=":
		return v <= t
	}
	return false
}

// recovered reports whether v has crossed back past the recovery threshold (hysteresis).
func (r Rule) recovered(v float64) bool {
	rt := r.Threshold
	if r.RecoveryThreshold != nil {
		rt = *r.RecoveryThreshold
	}
	switch r.Operator {
	case ">", ">=":
		return v < rt || (r.RecoveryThreshold == nil && !Breaches(r.Operator, v, r.Threshold))
	case "<", "<=":
		return v > rt || (r.RecoveryThreshold == nil && !Breaches(r.Operator, v, r.Threshold))
	}
	return true
}

// Point is one aggregated bucket of a series.
type Point struct {
	TS    time.Time
	Value float64
}

// Observation is the result of evaluating one series against a rule.
type Observation struct {
	HasData     bool
	Breaching   bool      // latest point breaches the threshold
	Sustained   bool      // breach has held for at least For and Consecutive points
	Recovered   bool      // latest point is past the recovery threshold
	Value       float64   // latest value
	LatestTS    time.Time // timestamp of latest point
	BreachSince time.Time // first point of the current breaching run
}

// EvaluateSeries evaluates a metric series. Evaluation uses data timestamps rather than
// wall-clock time so that provider metrics that arrive with several minutes of latency
// are evaluated correctly. Points older than staleAfter (relative to now) are ignored:
// a series with no fresh data yields HasData=false and never changes alert state.
func EvaluateSeries(r Rule, pts []Point, now time.Time, staleAfter time.Duration) Observation {
	if len(pts) == 0 {
		return Observation{}
	}
	sort.Slice(pts, func(i, j int) bool { return pts[i].TS.Before(pts[j].TS) })
	latest := pts[len(pts)-1]
	if now.Sub(latest.TS) > staleAfter {
		return Observation{}
	}
	o := Observation{HasData: true, Value: latest.Value, LatestTS: latest.TS}
	o.Breaching = Breaches(r.Operator, latest.Value, r.Threshold)
	o.Recovered = r.recovered(latest.Value)
	if !o.Breaching {
		return o
	}
	// Walk backwards over the contiguous breaching run. A gap larger than maxGap breaks
	// the run: we cannot claim "above 85% for 5 minutes" across missing data.
	const maxGap = 3 * time.Minute
	run := 1
	since := latest.TS
	for i := len(pts) - 2; i >= 0; i-- {
		p := pts[i]
		if !Breaches(r.Operator, p.Value, r.Threshold) || since.Sub(p.TS) > maxGap {
			break
		}
		run++
		since = p.TS
	}
	o.BreachSince = since
	need := r.Consecutive
	if need < 1 {
		need = 1
	}
	// A run of N one-minute buckets spans N minutes of wall time (each bucket represents
	// a minute), so the covered duration is latest-since plus one bucket.
	covered := latest.TS.Sub(since) + time.Minute
	o.Sustained = run >= need && covered >= r.For
	return o
}

// State of an alert instance.
type State string

const (
	StateNormal   State = "normal"
	StatePending  State = "pending"
	StateFiring   State = "firing"
	StateResolved State = "resolved"
)

// Instance is the persisted state of one (rule, subject, series) alert.
type Instance struct {
	State        State
	PendingSince *time.Time
	FiringSince  *time.Time
	ResolvedAt   *time.Time
	Breaches     int
	Value        float64
}

// Transition describes a state change.
type Transition struct {
	From, To State
	Message  string
}

// Step advances an instance given an observation. Without data the state is held.
func Step(r Rule, prev Instance, o Observation, now time.Time) (Instance, *Transition) {
	next := prev
	if prev.State == "" {
		next.State = StateNormal
	}
	if !o.HasData {
		return next, nil
	}
	next.Value = o.Value
	from := next.State
	switch next.State {
	case StateNormal, StateResolved:
		if o.Breaching {
			next.Breaches = 1
			if o.Sustained {
				next.State = StateFiring
				next.FiringSince = &now
				next.PendingSince = ptr(o.BreachSince)
			} else {
				next.State = StatePending
				next.PendingSince = ptr(o.BreachSince)
			}
		}
	case StatePending:
		if o.Breaching {
			next.Breaches++
			if o.Sustained {
				next.State = StateFiring
				next.FiringSince = &now
			}
		} else {
			next.State = StateNormal
			next.PendingSince = nil
			next.Breaches = 0
		}
	case StateFiring:
		if o.Recovered {
			next.State = StateResolved
			next.ResolvedAt = &now
			next.Breaches = 0
		}
	}
	if next.State == from {
		return next, nil
	}
	return next, &Transition{From: from, To: next.State, Message: describe(r, o)}
}

func ptr(t time.Time) *time.Time { return &t }

func describe(r Rule, o Observation) string {
	return fmt.Sprintf("%s: value %s %s threshold %s", r.Name, FormatValue(r.Metric, o.Value), r.Operator, FormatValue(r.Metric, r.Threshold))
}

// FormatValue renders a metric value for humans.
func FormatValue(metric string, v float64) string {
	switch {
	case math.IsNaN(v):
		return "n/a"
	case len(metric) > 6 && (metric[len(metric)-6:] == "_bytes"):
		return humanBytes(v)
	case metricIsPercent(metric):
		return fmt.Sprintf("%.1f%%", v)
	}
	if v == math.Trunc(v) {
		return fmt.Sprintf("%.0f", v)
	}
	return fmt.Sprintf("%.2f", v)
}

func metricIsPercent(m string) bool {
	switch m {
	case "cpu.utilization", "memory.utilization", "disk.utilization", "memory.swap_utilization",
		"db.cpu_utilization", "db.storage_utilization", "cpu.iowait", "cpu.steal", "cpu.core.utilization":
		return true
	}
	return false
}

func humanBytes(v float64) string {
	units := []string{"B", "KiB", "MiB", "GiB", "TiB"}
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	return fmt.Sprintf("%.1f %s", v, units[i])
}
