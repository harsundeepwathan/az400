// Package demo is a synthetic data source for the clearly labelled demonstration
// organization. It is selected only for cloud accounts whose auth_method is "demo";
// every sample it produces is stored with source "demo" and the UI shows a permanent
// "Demo environment — synthetic data" banner for demo organizations.
//
// The fleet includes deliberate problems so every workflow can be exercised:
// sustained high CPU, a nearly full data volume, a stopped VM, a resource the provider
// reports degraded, and a VM whose guest heartbeat stops.
package demo

import (
	"context"
	"fmt"
	"hash/fnv"
	"math"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// Adapter implements providers.Adapter with synthetic data.
type Adapter struct {
	provider model.Provider
	Now      func() time.Time
}

// New returns a demo adapter that impersonates the given provider's resource shapes.
func New(p model.Provider) *Adapter { return &Adapter{provider: p, Now: time.Now} }

// Provider implements providers.Adapter.
func (a *Adapter) Provider() model.Provider { return a.provider }

// Capabilities implements providers.Adapter.
func (a *Adapter) Capabilities() []providers.Capability {
	return []providers.Capability{{Key: "demo", Title: "Synthetic demonstration data", Status: providers.Implemented,
		Notes: "Not a real integration. Used only by the demo organization."}}
}

// MetricSupport implements providers.Adapter.
func (a *Adapter) MetricSupport() []providers.MetricSupport { return nil }

// ValidateCredentials implements providers.Adapter.
func (a *Adapter) ValidateCredentials(context.Context, providers.Account) (*providers.ValidationReport, error) {
	return &providers.ValidationReport{OK: true, Identity: "demo", ValidatedAt: a.Now().UTC(),
		Checks: []providers.PermissionCheck{{Check: "Demo account (synthetic data)", OK: true}}}, nil
}

type spec struct {
	name, typ, region, os, env string
	power                      model.PowerState
	cpuBase, memBase           float64
	disks                      map[string]float64
	issue                      string
}

func (a *Adapter) fleet() []spec {
	switch a.provider {
	case model.ProviderAzure:
		return []spec{
			{name: "web-prod-01", typ: "vm", region: "westeurope", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 38, memBase: 61, disks: map[string]float64{"/": 54, "/var/log": 41}},
			{name: "web-prod-02", typ: "vm", region: "westeurope", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 42, memBase: 58, disks: map[string]float64{"/": 57, "/var/log": 44}},
			{name: "api-prod-01", typ: "vm", region: "westeurope", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 91, memBase: 72, disks: map[string]float64{"/": 48}, issue: "cpu"},
			{name: "sql-prod-01", typ: "vm", region: "westeurope", os: "windows", env: "production", power: model.PowerRunning, cpuBase: 35, memBase: 83, disks: map[string]float64{"C:": 61, "D:": 92.4}, issue: "disk"},
			{name: "dc-01", typ: "vm", region: "northeurope", os: "windows", env: "production", power: model.PowerRunning, cpuBase: 12, memBase: 47, disks: map[string]float64{"C:": 39}},
			{name: "batch-dev-01", typ: "vm", region: "northeurope", os: "linux", env: "development", power: model.PowerDeallocated, disks: map[string]float64{"/": 22}},
			{name: "jump-01", typ: "vm", region: "westeurope", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 6, memBase: 30, disks: map[string]float64{"/": 33}, issue: "heartbeat"},
			{name: "lb-web-prod", typ: "load_balancer", region: "westeurope", env: "production", power: model.PowerNotApplicable},
			{name: "orders-api", typ: "app_service", region: "westeurope", env: "production", power: model.PowerRunning},
			{name: "stprodassets", typ: "storage_account", region: "westeurope", env: "production", power: model.PowerNotApplicable},
			{name: "aks-prod", typ: "kubernetes_cluster", region: "westeurope", env: "production", power: model.PowerRunning, cpuBase: 55, memBase: 66},
		}
	case model.ProviderDigitalOcean:
		return []spec{
			{name: "edge-ams3-01", typ: "vm", region: "ams3", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 22, memBase: 51, disks: map[string]float64{"/": 63}},
			{name: "edge-nyc1-01", typ: "vm", region: "nyc1", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 27, memBase: 55, disks: map[string]float64{"/": 58}},
			{name: "worker-fra1-01", typ: "vm", region: "fra1", os: "linux", env: "staging", power: model.PowerRunning, cpuBase: 15, disks: map[string]float64{}, issue: "noagent"},
			{name: "pg-main", typ: "managed_database", region: "fra1", env: "production", power: model.PowerRunning},
			{name: "lb-edge", typ: "load_balancer", region: "ams3", env: "production", power: model.PowerRunning},
		}
	case model.ProviderAlibaba:
		return []spec{
			{name: "ecs-hk-app-01", typ: "vm", region: "cn-hongkong", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 31, memBase: 64, disks: map[string]float64{"/": 71}},
			{name: "ecs-sg-app-01", typ: "vm", region: "ap-southeast-1", os: "linux", env: "production", power: model.PowerRunning, cpuBase: 29, memBase: 60, disks: map[string]float64{"/": 66}, issue: "degraded"},
			{name: "rds-sg-01", typ: "managed_database", region: "ap-southeast-1", env: "production", power: model.PowerRunning},
		}
	}
	return nil
}

func (a *Adapter) id(s spec) string { return fmt.Sprintf("demo:%s:%s", a.provider, s.name) }

// Discover implements providers.Adapter.
func (a *Adapter) Discover(_ context.Context, acct providers.Account) ([]model.DiscoveredResource, error) {
	var out []model.DiscoveredResource
	var lbID string
	for _, s := range a.fleet() {
		if s.typ == "load_balancer" {
			lbID = a.id(s)
		}
	}
	for _, s := range a.fleet() {
		d := model.DiscoveredResource{
			ProviderResourceID: a.id(s), ExternalAccountID: acct.ExternalID, Name: s.name, Type: model.ResourceType(s.typ),
			NativeType: "demo/" + s.typ, Region: s.region, Tags: map[string]string{"environment": s.env, "demo": "true"},
			OSType: s.os, PowerState: s.power, ProviderStateRaw: string(s.power), Config: map[string]any{"demo": true},
		}
		if s.os == "linux" {
			d.OSName = "Ubuntu 24.04 LTS"
		} else if s.os == "windows" {
			d.OSName = "Windows Server 2022"
		}
		if s.typ == "vm" && lbID != "" && (s.name == "web-prod-01" || s.name == "web-prod-02" || s.name == "edge-ams3-01") {
			d.Relations = []model.Relation{{ToProviderResourceID: lbID, Kind: "backend_of"}}
		}
		out = append(out, d)
	}
	return out, nil
}

func wave(seed string, t time.Time, base, amp float64) float64 {
	h := fnv.New32a()
	h.Write([]byte(seed))
	phase := float64(h.Sum32()%1000) / 1000 * 2 * math.Pi
	m := float64(t.Unix()) / 60
	v := base + amp*math.Sin(m/37+phase) + amp/2*math.Sin(m/7.3+phase*2)
	return math.Max(0, math.Min(100, v))
}

// CollectMetrics implements providers.Adapter.
func (a *Adapter) CollectMetrics(_ context.Context, _ providers.Account, refs []model.ResourceRef, from, to time.Time) (*providers.MetricsResult, error) {
	res := providers.NewMetricsResult()
	byID := map[string]spec{}
	for _, s := range a.fleet() {
		byID[a.id(s)] = s
	}
	for _, ref := range refs {
		s, ok := byID[ref.ProviderResourceID]
		if !ok || s.power.IsOff() || s.cpuBase == 0 {
			continue
		}
		for t := from.Truncate(time.Minute); !t.After(to); t = t.Add(time.Minute) {
			cpuAmp := 8.0
			if s.issue == "cpu" {
				cpuAmp = 2
			}
			res.Add(ref.ID,
				model.Sample{Metric: "cpu.utilization", TS: t, Value: wave(s.name+"cpu", t, s.cpuBase, cpuAmp)},
				model.Sample{Metric: "net.in_bytes_per_sec", TS: t, Value: 1e5 * (1 + wave(s.name+"net", t, 50, 30)/50)},
				model.Sample{Metric: "net.out_bytes_per_sec", TS: t, Value: 2e5 * (1 + wave(s.name+"neto", t, 50, 30)/50)},
			)
			if s.issue == "noagent" {
				continue
			}
			total := 8.0 * 1024 * 1024 * 1024
			mem := wave(s.name+"mem", t, s.memBase, 3)
			res.Add(ref.ID,
				model.Sample{Metric: "memory.utilization", TS: t, Value: mem},
				model.Sample{Metric: "memory.total_bytes", TS: t, Value: total},
				model.Sample{Metric: "memory.available_bytes", TS: t, Value: total * (100 - mem) / 100},
			)
			for mount, pct := range s.disks {
				size := 128.0 * 1024 * 1024 * 1024
				growth := float64(t.Unix()%86400) / 86400 * 0.4
				used := math.Min(99.5, pct+growth)
				series := "mount=" + mount
				res.Add(ref.ID,
					model.Sample{Metric: "disk.utilization", Series: series, TS: t, Value: used},
					model.Sample{Metric: "disk.total_bytes", Series: series, TS: t, Value: size},
					model.Sample{Metric: "disk.used_bytes", Series: series, TS: t, Value: size * used / 100},
				)
			}
		}
		if s.issue == "noagent" {
			for _, m := range []string{"memory.utilization", "disk.utilization"} {
				res.MarkUnavailable(ref.ID, m, "DigitalOcean metrics agent (do-agent) not installed on this Droplet")
			}
		}
	}
	return res, nil
}

// CollectHealth implements providers.Adapter.
func (a *Adapter) CollectHealth(_ context.Context, _ providers.Account, refs []model.ResourceRef) ([]model.HealthObservation, error) {
	var out []model.HealthObservation
	byID := map[string]spec{}
	for _, s := range a.fleet() {
		byID[a.id(s)] = s
	}
	for _, r := range refs {
		s := byID[r.ProviderResourceID]
		h := model.HealthAvailable
		reason := ""
		if s.issue == "degraded" {
			h, reason = model.HealthDegraded, "Demo: provider reports degraded performance on the underlying host"
		}
		out = append(out, model.HealthObservation{ProviderResourceID: r.ProviderResourceID, Health: h, Reason: reason, ObservedAt: a.Now().UTC()})
	}
	return out, nil
}

// CollectHeartbeats implements providers.Adapter: every running demo VM heartbeats
// except the one scripted to go silent.
func (a *Adapter) CollectHeartbeats(_ context.Context, _ providers.Account, _ time.Time) ([]model.HeartbeatObservation, error) {
	var out []model.HeartbeatObservation
	now := a.Now().UTC()
	for _, s := range a.fleet() {
		if s.typ != "vm" || s.power.IsOff() || s.issue == "noagent" {
			continue
		}
		last := now.Add(-20 * time.Second)
		if s.issue == "heartbeat" {
			last = now.Add(-11 * time.Minute)
		}
		out = append(out, model.HeartbeatObservation{ProviderResourceID: a.id(s), Computer: s.name, LastHeartbeat: last, Source: "demo"})
	}
	return out, nil
}

// CollectEvents implements providers.Adapter.
func (a *Adapter) CollectEvents(_ context.Context, _ providers.Account, since time.Time) ([]model.Event, error) {
	if a.provider != model.ProviderAzure {
		return nil, nil
	}
	now := a.Now().UTC().Truncate(time.Hour)
	return []model.Event{
		{ProviderResourceID: "demo:azure:api-prod-01", ExternalID: "demo-" + now.Format("2006010215") + "-1", Kind: "azure_activity:administrative",
			Severity: "info", Message: "Demo: Update Virtual Machine (resize to Standard_D2s_v5): Succeeded by ops@demo.local", At: now.Add(-25 * time.Minute)},
		{ProviderResourceID: "demo:azure:batch-dev-01", ExternalID: "demo-" + now.Format("2006010215") + "-2", Kind: "azure_activity:administrative",
			Severity: "info", Message: "Demo: Deallocate Virtual Machine: Succeeded by scheduler@demo.local", At: now.Add(-50 * time.Minute)},
	}, nil
}
