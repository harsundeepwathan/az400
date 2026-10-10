// Package providers defines the cloud provider adapter contract.
//
// Adapters declare what they can actually do (Capabilities) instead of pretending every
// cloud exposes identical telemetry. Callers must consult capabilities and treat a
// missing capability as "no data", never as "healthy" or "down".
package providers

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
)

// Status of a capability in a given adapter build.
type Status string

const (
	Implemented    Status = "implemented"     // real API integration, contract-tested
	Experimental   Status = "experimental"    // real API integration, limited verification
	NotImplemented Status = "not_implemented" // known gap
	Unsupported    Status = "unsupported"     // provider does not expose this
)

// Capability describes one monitoring capability and its prerequisites.
type Capability struct {
	Key          string   `json:"key"`
	Title        string   `json:"title"`
	Status       Status   `json:"status"`
	Requires     []string `json:"requires,omitempty"` // e.g. "Azure Monitor Agent + Log Analytics workspace"
	ResourceType []string `json:"resource_types,omitempty"`
	Notes        string   `json:"notes,omitempty"`
}

// MetricSupport declares which normalized metrics an adapter can return per resource type
// and whether a guest agent is needed.
type MetricSupport struct {
	ResourceType  model.ResourceType `json:"resource_type"`
	Metric        string             `json:"metric"`
	NativeMetric  string             `json:"native_metric"`
	RequiresAgent bool               `json:"requires_agent"`
	Notes         string             `json:"notes,omitempty"`
}

// Credentials is the decrypted credential document for an account. Keys depend on the
// provider; adapters validate the shape.
type Credentials map[string]string

// Account is the runtime view of a cloud account handed to an adapter.
type Account struct {
	ID          string
	OrgID       string
	ExternalID  string
	AuthMethod  string
	Credentials Credentials
	Config      map[string]any
}

// PermissionCheck is one line of a credential validation report.
type PermissionCheck struct {
	Check   string `json:"check"`
	OK      bool   `json:"ok"`
	Detail  string `json:"detail,omitempty"`
	Missing string `json:"missing,omitempty"` // the permission or prerequisite to add
}

// ValidationReport is returned by ValidateCredentials.
type ValidationReport struct {
	OK          bool              `json:"ok"`
	Identity    string            `json:"identity,omitempty"`
	Scopes      []string          `json:"scopes,omitempty"` // subscriptions / regions / projects reachable
	Checks      []PermissionCheck `json:"checks"`
	ValidatedAt time.Time         `json:"validated_at"`
}

// MetricsResult carries samples plus explicit gaps.
type MetricsResult struct {
	Samples map[string][]model.Sample // keyed by Skywatch resource ID
	// Unavailable records metrics that could not be retrieved and why, keyed by
	// resource ID then metric. Example: "memory.utilization" -> "agent not installed".
	Unavailable map[string]map[string]string
}

// NewMetricsResult returns an empty result.
func NewMetricsResult() *MetricsResult {
	return &MetricsResult{Samples: map[string][]model.Sample{}, Unavailable: map[string]map[string]string{}}
}

// Add appends samples for a resource.
func (r *MetricsResult) Add(resourceID string, s ...model.Sample) {
	r.Samples[resourceID] = append(r.Samples[resourceID], s...)
}

// MarkUnavailable records why a metric is missing.
func (r *MetricsResult) MarkUnavailable(resourceID, metric, reason string) {
	m := r.Unavailable[resourceID]
	if m == nil {
		m = map[string]string{}
		r.Unavailable[resourceID] = m
	}
	m[metric] = reason
}

// Adapter is the contract every provider integration implements.
type Adapter interface {
	Provider() model.Provider
	Capabilities() []Capability
	MetricSupport() []MetricSupport
	// ValidateCredentials checks connectivity and the read permissions Skywatch needs.
	ValidateCredentials(ctx context.Context, acct Account) (*ValidationReport, error)
	// Discover lists resources visible to the account.
	Discover(ctx context.Context, acct Account) ([]model.DiscoveredResource, error)
	// CollectMetrics retrieves supported metrics for the given resources over [from, to].
	CollectMetrics(ctx context.Context, acct Account, refs []model.ResourceRef, from, to time.Time) (*MetricsResult, error)
	// CollectHealth retrieves provider health signals. Adapters without a health API
	// return ErrNotSupported.
	CollectHealth(ctx context.Context, acct Account, refs []model.ResourceRef) ([]model.HealthObservation, error)
	// CollectHeartbeats retrieves guest heartbeats from provider-side agents. Adapters
	// without such a source return ErrNotSupported.
	CollectHeartbeats(ctx context.Context, acct Account, since time.Time) ([]model.HeartbeatObservation, error)
	// CollectEvents retrieves recent infrastructure change events.
	CollectEvents(ctx context.Context, acct Account, since time.Time) ([]model.Event, error)
}

// Common errors. Collectors classify errors with these so the platform can distinguish
// "the cloud API failed" from "the customer resource failed".
var (
	ErrNotSupported = errors.New("capability not supported by provider")
	ErrInvalidCreds = errors.New("invalid or expired credentials")
	ErrForbidden    = errors.New("insufficient permissions")
)

// ThrottledError is returned when the provider rate-limited us.
type ThrottledError struct {
	RetryAfter time.Duration
	Detail     string
}

func (e *ThrottledError) Error() string {
	return fmt.Sprintf("provider throttled request (retry after %s): %s", e.RetryAfter, e.Detail)
}

// IsThrottled reports whether err is a ThrottledError.
func IsThrottled(err error) (*ThrottledError, bool) {
	var t *ThrottledError
	if errors.As(err, &t) {
		return t, true
	}
	return nil, false
}

// CallStats is updated by adapters so the platform can report API usage and throttling.
// It is safe for concurrent use.
type CallStats struct {
	calls     atomic.Int64
	throttled atomic.Int64
}

// AddCall records one outbound API attempt.
func (s *CallStats) AddCall() { s.calls.Add(1) }

// AddThrottled records one throttled response.
func (s *CallStats) AddThrottled() { s.throttled.Add(1) }

// Calls returns the number of attempts recorded.
func (s *CallStats) Calls() int { return int(s.calls.Load()) }

// Throttled returns the number of throttled responses recorded.
func (s *CallStats) Throttled() int { return int(s.throttled.Load()) }

type statsKey struct{}

// WithStats attaches a CallStats collector to the context.
func WithStats(ctx context.Context, s *CallStats) context.Context {
	return context.WithValue(ctx, statsKey{}, s)
}

// StatsFrom returns the CallStats attached to ctx, or a throwaway one.
func StatsFrom(ctx context.Context) *CallStats {
	if s, ok := ctx.Value(statsKey{}).(*CallStats); ok {
		return s
	}
	return &CallStats{}
}
