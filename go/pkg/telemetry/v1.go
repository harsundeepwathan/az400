// Package telemetry defines the versioned contract between the Skywatch agent and the
// ingest API. Version 1 is documented in docs/api/agent-v1.md and its JSON Schema lives
// in docs/api/agent-v1.schema.json. Changes must be additive; breaking changes require
// a new version path (/v2/agent/...).
package telemetry

import (
	"errors"
	"fmt"
	"regexp"
	"time"
)

// Version is the contract version string sent in every batch.
const Version = "1"

// Limits enforced by the ingest API (and respected by the agent).
const (
	MaxBatchBytes   = 1 << 20 // 1 MiB request body
	MaxSamples      = 5000
	MaxServices     = 500
	MaxEvents       = 200
	MaxNameLen      = 256
	MaxSeriesLen    = 256
	MaxMessageLen   = 2048
	DefaultInterval = 60 * time.Second
)

// EnrollRequest exchanges a one-time enrollment token for an agent identity.
type EnrollRequest struct {
	EnrollmentToken string    `json:"enrollment_token"`
	Host            HostInfo  `json:"host"`
	AgentVersion    string    `json:"agent_version"`
	Cloud           CloudInfo `json:"cloud"`
}

// EnrollResponse returns the agent identity. The secret is shown exactly once.
type EnrollResponse struct {
	AgentID     string      `json:"agent_id"`
	AgentSecret string      `json:"agent_secret"`
	ResourceID  string      `json:"resource_id"`
	Config      AgentConfig `json:"config"`
}

// RotateResponse returns a new secret. The previous secret stays valid for a grace
// period so an agent that crashes mid-rotation can still authenticate.
type RotateResponse struct {
	AgentSecret      string    `json:"agent_secret"`
	PreviousValidTil time.Time `json:"previous_valid_until"`
}

// AgentConfig is server-driven configuration returned on enrollment and with each
// batch acknowledgement.
type AgentConfig struct {
	HeartbeatIntervalSeconds int      `json:"heartbeat_interval_seconds"`
	MetricsIntervalSeconds   int      `json:"metrics_interval_seconds"`
	ServiceIntervalSeconds   int      `json:"service_interval_seconds"`
	WatchedServices          []string `json:"watched_services"`
	DiscoverServices         bool     `json:"discover_services"`
	ExcludeMounts            []string `json:"exclude_mounts,omitempty"`
}

// HostInfo describes the host the agent runs on.
type HostInfo struct {
	Hostname      string    `json:"hostname"`
	MachineID     string    `json:"machine_id,omitempty"` // /etc/machine-id or Windows MachineGuid
	OSType        string    `json:"os_type"`              // windows | linux
	OSName        string    `json:"os_name"`
	OSVersion     string    `json:"os_version"`
	KernelVersion string    `json:"kernel_version,omitempty"`
	Arch          string    `json:"arch"`
	BootTime      time.Time `json:"boot_time"`
	CPUCount      int       `json:"cpu_count"`
	MemoryBytes   uint64    `json:"memory_bytes"`
}

// CloudInfo is read from the local instance metadata service when available and is used
// to link the agent to a discovered cloud resource.
type CloudInfo struct {
	Provider   string `json:"provider,omitempty"`    // azure | digitalocean | alibaba
	ResourceID string `json:"resource_id,omitempty"` // Azure resource ID, droplet ID, ECS instance ID
	Region     string `json:"region,omitempty"`
	InstanceID string `json:"instance_id,omitempty"`
}

// Batch is one telemetry upload.
type Batch struct {
	Version  string        `json:"version"`
	BatchID  string        `json:"batch_id"` // UUID, idempotency key
	Seq      int64         `json:"seq"`      // monotonically increasing per agent
	SentAt   time.Time     `json:"sent_at"`
	Host     *HostInfo     `json:"host,omitempty"` // sent on start and when changed
	Agent    AgentHealth   `json:"agent"`
	Metrics  []Sample      `json:"metrics,omitempty"`
	Services []Service     `json:"services,omitempty"`
	Events   []Event       `json:"events,omitempty"`
	Partial  []PartialInfo `json:"partial,omitempty"` // collectors that failed this cycle
}

// AgentHealth is the agent's self-report.
type AgentHealth struct {
	Version        string  `json:"version"`
	QueueDepth     int     `json:"queue_depth"`
	DroppedBatches int64   `json:"dropped_batches"`
	CPUPercent     float64 `json:"cpu_percent"`
	RSSBytes       uint64  `json:"rss_bytes"`
	UptimeSeconds  int64   `json:"uptime_seconds"`
}

// PartialInfo reports a collector that failed (e.g. service manager unreachable).
type PartialInfo struct {
	Collector string `json:"collector"`
	Error     string `json:"error"`
}

// Sample is a normalized metric sample.
type Sample struct {
	Metric string    `json:"m"`
	Series string    `json:"s,omitempty"`
	TS     time.Time `json:"t"`
	Value  float64   `json:"v"`
}

// Service is the observed state of an OS service.
type Service struct {
	Platform    string `json:"platform"` // windows | systemd
	Name        string `json:"name"`
	DisplayName string `json:"display_name,omitempty"`
	State       string `json:"state"`               // running | stopped | failed | starting | stopping | unknown
	SubState    string `json:"sub_state,omitempty"` // systemd SubState / Windows raw state
	StartupType string `json:"startup_type,omitempty"`
	PID         int    `json:"pid,omitempty"`
	Restarts    int    `json:"restarts,omitempty"` // systemd NRestarts
}

// Event is an OS event (Windows Event Log / journal) selected by the agent.
type Event struct {
	Source   string    `json:"source"`
	Kind     string    `json:"kind"`
	Severity string    `json:"severity"`
	Message  string    `json:"message"`
	At       time.Time `json:"at"`
	ID       string    `json:"id,omitempty"`
}

// BatchAck acknowledges a batch.
type BatchAck struct {
	Accepted  int         `json:"accepted"`
	Duplicate bool        `json:"duplicate"`
	Config    AgentConfig `json:"config"`
}

var (
	metricRe = regexp.MustCompile(`^[a-z][a-z0-9_.]{0,127}$`)
	uuidRe   = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
)

// Validate enforces the contract's structural limits.
func (b *Batch) Validate() error {
	if b.Version != Version {
		return fmt.Errorf("unsupported telemetry version %q", b.Version)
	}
	if !uuidRe.MatchString(b.BatchID) {
		return errors.New("batch_id must be a UUID")
	}
	if b.Seq < 0 {
		return errors.New("seq must be >= 0")
	}
	if len(b.Metrics) > MaxSamples || len(b.Services) > MaxServices || len(b.Events) > MaxEvents {
		return errors.New("batch exceeds item limits")
	}
	for i, m := range b.Metrics {
		if !metricRe.MatchString(m.Metric) {
			return fmt.Errorf("metrics[%d]: invalid metric name", i)
		}
		if len(m.Series) > MaxSeriesLen {
			return fmt.Errorf("metrics[%d]: series too long", i)
		}
		if m.TS.IsZero() {
			return fmt.Errorf("metrics[%d]: missing timestamp", i)
		}
	}
	for i, s := range b.Services {
		if s.Name == "" || len(s.Name) > MaxNameLen || (s.Platform != "windows" && s.Platform != "systemd") {
			return fmt.Errorf("services[%d]: invalid", i)
		}
		switch s.State {
		case "running", "stopped", "failed", "starting", "stopping", "unknown":
		default:
			return fmt.Errorf("services[%d]: invalid state %q", i, s.State)
		}
	}
	for i, e := range b.Events {
		if len(e.Message) > MaxMessageLen || e.At.IsZero() {
			return fmt.Errorf("events[%d]: invalid", i)
		}
	}
	return nil
}
