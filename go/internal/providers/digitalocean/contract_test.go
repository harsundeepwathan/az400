package digitalocean

// Mocked contract tests. Fixture shapes follow the DigitalOcean API v2 responses
// (and the fixtures in godo's own test suite). Live steps: docs/LIVE_VERIFICATION.md.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

type fakeDO struct {
	t         *testing.T
	noAgent   map[string]bool
	throttle  bool
	forbidden map[string]bool
}

func (f *fakeDO) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer dop_v1_test" {
		w.WriteHeader(401)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "Unauthorized", "message": "Unable to authenticate you"})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if f.throttle {
		w.Header().Set("RateLimit-Reset", strconv.FormatInt(time.Now().Add(90*time.Second).Unix(), 10))
		w.WriteHeader(429)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "too_many_requests", "message": "API Rate limit exceeded."})
		return
	}
	for prefix := range f.forbidden {
		if strings.HasPrefix(r.URL.Path, prefix) {
			w.WriteHeader(403)
			_ = json.NewEncoder(w).Encode(map[string]any{"id": "forbidden", "message": "You are not authorized to perform this operation"})
			return
		}
	}
	q := r.URL.Query()
	write := func(v any) { _ = json.NewEncoder(w).Encode(v) }
	links := map[string]any{"pages": map[string]any{}}
	switch {
	case r.URL.Path == "/v2/account":
		write(map[string]any{"account": map[string]any{"email": "ops@example.com", "status": "active", "team": map[string]any{"uuid": "t1", "name": "Edge"}}})
	case r.URL.Path == "/v2/droplets":
		write(map[string]any{"droplets": []any{
			map[string]any{"id": 101, "name": "edge-01", "status": "active", "memory": 2048, "vcpus": 2, "disk": 50, "size_slug": "s-2vcpu-2gb",
				"region": map[string]any{"slug": "ams3"}, "image": map[string]any{"distribution": "Ubuntu", "name": "24.04 (LTS) x64"}, "tags": []any{"env:production", "web"}},
			map[string]any{"id": 102, "name": "worker-01", "status": "active", "region": map[string]any{"slug": "fra1"}, "tags": []any{}},
			map[string]any{"id": 103, "name": "old-01", "status": "off", "region": map[string]any{"slug": "fra1"}},
		}, "links": links, "meta": map[string]any{"total": 3}})
	case r.URL.Path == "/v2/load_balancers":
		write(map[string]any{"load_balancers": []any{map[string]any{"id": "lb-1", "name": "lb-edge", "status": "active",
			"region": map[string]any{"slug": "ams3"}, "droplet_ids": []any{101}}}, "links": links})
	case r.URL.Path == "/v2/databases":
		write(map[string]any{"databases": []any{map[string]any{"id": "db-1", "name": "pg-main", "engine": "pg", "version": "16", "region": "fra1", "status": "online"}}})
	case r.URL.Path == "/v2/kubernetes/clusters":
		write(map[string]any{"kubernetes_clusters": []any{map[string]any{"id": "k-1", "name": "doks", "region": "ams3", "version": "1.31",
			"status": map[string]any{"state": "running"}}}, "links": links})
	case r.URL.Path == "/v2/volumes":
		write(map[string]any{"volumes": []any{map[string]any{"id": "v-1", "name": "data", "size_gigabytes": 100, "droplet_ids": []any{101},
			"region": map[string]any{"slug": "ams3"}}}, "links": links})
	case r.URL.Path == "/v2/actions":
		write(map[string]any{"actions": []any{map[string]any{"id": 9, "status": "completed", "type": "power_off", "started_at": time.Now().UTC().Format(time.RFC3339),
			"resource_id": 103, "resource_type": "droplet"}}, "links": links})
	case strings.HasPrefix(r.URL.Path, "/v2/monitoring/metrics/droplet/"):
		host := q.Get("host_id")
		if q.Get("start") == "" || q.Get("end") == "" || host == "" {
			f.t.Errorf("monitoring request missing host_id/start/end: %s", r.URL.RawQuery)
		}
		metric := strings.TrimPrefix(r.URL.Path, "/v2/monitoring/metrics/droplet/")
		var result []any
		t0 := int64(1760000000)
		switch metric {
		case "cpu":
			// Per-mode cumulative CPU seconds for a 2-vCPU droplet; between samples
			// (120s => 240 CPU-seconds) 60 seconds are busy => 25% utilization.
			result = []any{
				stream(map[string]string{"mode": "idle"}, [][2]any{{t0, "1000"}, {t0 + 120, "1180"}}),
				stream(map[string]string{"mode": "user"}, [][2]any{{t0, "100"}, {t0 + 120, "150"}}),
				stream(map[string]string{"mode": "system"}, [][2]any{{t0, "50"}, {t0 + 120, "60"}}),
			}
		case "bandwidth":
			if q.Get("interface") != "public" || (q.Get("direction") != "inbound" && q.Get("direction") != "outbound") {
				f.t.Errorf("bandwidth query: %s", r.URL.RawQuery)
			}
			result = []any{stream(map[string]string{"direction": q.Get("direction"), "interface": "public"}, [][2]any{{t0, "8"}})}
		case "memory_total", "memory_available", "filesystem_size", "filesystem_free", "load_1":
			if f.noAgent[host] {
				result = []any{}
				break
			}
			v := map[string]string{"memory_total": "4000000000", "memory_available": "1000000000", "filesystem_size": "100000000000",
				"filesystem_free": "10000000000", "load_1": "0.42"}[metric]
			labels := map[string]string{}
			if strings.HasPrefix(metric, "filesystem") {
				labels = map[string]string{"device": "/dev/vda1", "fstype": "ext4", "mountpoint": "/"}
			}
			result = []any{stream(labels, [][2]any{{t0 + 120, v}})}
		default:
			f.t.Errorf("unexpected metric %s", metric)
		}
		write(map[string]any{"status": "success", "data": map[string]any{"resultType": "matrix", "result": result}})
	default:
		f.t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		w.WriteHeader(404)
	}
}

func stream(labels map[string]string, vals [][2]any) map[string]any {
	return map[string]any{"metric": labels, "values": vals}
}

func newTest(t *testing.T) (*Adapter, *fakeDO, providers.Account) {
	f := &fakeDO{t: t, noAgent: map[string]bool{}, forbidden: map[string]bool{}}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	return New(Options{BaseURL: srv.URL + "/", HTTPClient: srv.Client()}), f,
		providers.Account{ID: "a", Credentials: providers.Credentials{"token": "dop_v1_test"}}
}

func TestDiscover(t *testing.T) {
	a, _, acct := newTest(t)
	res, err := a.Discover(context.Background(), acct)
	if err != nil {
		t.Fatal(err)
	}
	byName := map[string]model.DiscoveredResource{}
	for _, r := range res {
		byName[r.Name] = r
	}
	if len(res) != 7 {
		t.Fatalf("expected 7 resources, got %d", len(res))
	}
	e := byName["edge-01"]
	if e.PowerState != model.PowerRunning || e.Region != "ams3" || e.Tags["env"] != "production" || e.Environment() != "" && e.Tags["env"] == "" {
		t.Errorf("edge-01 = %+v", e)
	}
	if len(e.Relations) != 1 || e.Relations[0].ToProviderResourceID != "lb:lb-1" {
		t.Errorf("droplet should be backend_of the LB: %+v", e.Relations)
	}
	if byName["old-01"].PowerState != model.PowerStopped {
		t.Error("off droplet must be stopped")
	}
	if byName["pg-main"].Type != model.TypeManagedDB || byName["doks"].Type != model.TypeK8sCluster || byName["data"].Type != model.TypeVolume {
		t.Error("managed resource types")
	}
}

func TestMetricsAndMissingAgent(t *testing.T) {
	a, f, acct := newTest(t)
	f.noAgent["102"] = true
	now := time.Now()
	res, err := a.CollectMetrics(context.Background(), acct, []model.ResourceRef{
		{ID: "r101", ProviderResourceID: "101", Type: model.TypeVM, PowerState: model.PowerRunning},
		{ID: "r102", ProviderResourceID: "102", Type: model.TypeVM, PowerState: model.PowerRunning},
		{ID: "r103", ProviderResourceID: "103", Type: model.TypeVM, PowerState: model.PowerStopped},
	}, now.Add(-10*time.Minute), now)
	if err != nil {
		t.Fatal(err)
	}
	vals := map[string]float64{}
	for _, s := range res.Samples["r101"] {
		vals[s.Metric+s.Series] = s.Value
	}
	if vals["cpu.utilization"] != 25 {
		t.Errorf("cpu from mode counters = %v, want 25", vals["cpu.utilization"])
	}
	if vals["memory.utilization"] != 75 || vals["disk.utilizationmount=/"] != 90 || vals["net.in_bytes_per_sec"] != 1e6 {
		t.Errorf("values = %v", vals)
	}
	if !strings.Contains(res.Unavailable["r102"]["memory.utilization"], "do-agent") || !strings.Contains(res.Unavailable["r102"]["disk.utilization"], "do-agent") {
		t.Errorf("missing agent must be explicit: %v", res.Unavailable["r102"])
	}
	for _, s := range res.Samples["r102"] {
		if s.Metric == "memory.utilization" {
			t.Error("no memory samples may be invented without the agent")
		}
	}
	if res.Unavailable["r103"]["cpu.utilization"] == "" {
		t.Error("off droplet should be marked unavailable")
	}
}

func TestErrorsClassified(t *testing.T) {
	a, f, acct := newTest(t)
	bad := acct
	bad.Credentials = providers.Credentials{"token": "nope"}
	if _, err := a.Discover(context.Background(), bad); !errors.Is(err, providers.ErrInvalidCreds) {
		t.Errorf("401 -> ErrInvalidCreds, got %v", err)
	}
	f.throttle = true
	_, err := a.Discover(context.Background(), acct)
	te, ok := providers.IsThrottled(err)
	if !ok || te.RetryAfter < time.Minute {
		t.Errorf("429 -> throttled with reset, got %v", err)
	}
}

func TestValidateReportsMissingScopes(t *testing.T) {
	a, f, acct := newTest(t)
	f.forbidden["/v2/databases"] = true
	rep, err := a.ValidateCredentials(context.Background(), acct)
	if err != nil {
		t.Fatal(err)
	}
	if rep.OK || rep.Identity != "ops@example.com" {
		t.Fatalf("report = %+v", rep)
	}
	found := false
	for _, c := range rep.Checks {
		if c.Check == "List Managed Databases" {
			found = !c.OK && c.Missing == "token scope database:read"
		}
	}
	if !found {
		t.Errorf("missing database:read scope not reported: %+v", rep.Checks)
	}
	_ = fmt.Sprint()
}
