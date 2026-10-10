package alibaba

// Mocked contract tests. The fake server answers RPC-style requests (Action parameter)
// with the documented JSON response shapes for ECS and CloudMonitor.

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

type fakeAli struct {
	t        *testing.T
	mu       sync.Mutex
	actions  []string
	throttle bool
	badKey   bool
}

func (f *fakeAli) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	action := r.Form.Get("Action")
	if action == "" {
		action = r.Header.Get("x-acs-action")
	}
	f.mu.Lock()
	f.actions = append(f.actions, action)
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	write := func(code int, v any) { w.WriteHeader(code); _ = json.NewEncoder(w).Encode(v) }
	if f.badKey {
		write(404, map[string]any{"Code": "InvalidAccessKeyId.NotFound", "Message": "Specified access key is not found.", "RequestId": "r"})
		return
	}
	if f.throttle {
		write(400, map[string]any{"Code": "Throttling.User", "Message": "Request was denied due to user flow control.", "RequestId": "r"})
		return
	}
	switch action {
	case "DescribeInstances":
		if r.Form.Get("NextToken") == "" && !strings.Contains(r.URL.RawQuery, "NextToken") {
			write(200, map[string]any{"RequestId": "r", "NextToken": "page2", "Instances": map[string]any{"Instance": []any{
				map[string]any{"InstanceId": "i-hk01", "InstanceName": "app-hk-01", "Status": "Running", "RegionId": "cn-hongkong",
					"ZoneId": "cn-hongkong-b", "OSType": "linux", "OSName": "Alibaba Cloud Linux 3", "InstanceType": "ecs.g7.large", "Cpu": 2, "Memory": 8192,
					"Tags": map[string]any{"Tag": []any{map[string]any{"TagKey": "environment", "TagValue": "production"}}}},
			}}})
			return
		}
		write(200, map[string]any{"RequestId": "r", "NextToken": "", "Instances": map[string]any{"Instance": []any{
			map[string]any{"InstanceId": "i-hk02", "InstanceName": "batch-hk-02", "Status": "Stopped", "RegionId": "cn-hongkong", "OSType": "windows"},
		}}})
	case "DescribeInstancesFullStatus":
		write(200, map[string]any{"RequestId": "r", "InstanceFullStatusSet": map[string]any{"InstanceFullStatusType": []any{
			map[string]any{"InstanceId": "i-hk01", "HealthStatus": map[string]any{"Name": "Impaired", "Code": 129}, "Status": map[string]any{"Name": "Running", "Code": 1}},
		}}})
	case "DescribeMetricList":
		metric := r.Form.Get("MetricName")
		if r.Form.Get("Namespace") != "acs_ecs_dashboard" || r.Form.Get("Period") != "60" || !strings.Contains(r.Form.Get("Dimensions"), "i-hk01") {
			f.t.Errorf("DescribeMetricList contract: %v", r.Form)
		}
		ts := time.Now().Add(-time.Minute).UnixMilli()
		var dps []map[string]any
		switch metric {
		case "CPUUtilization":
			dps = []map[string]any{{"timestamp": ts, "instanceId": "i-hk01", "Average": 37.5, "Maximum": 40, "Minimum": 30}}
		case "InternetInRate":
			dps = []map[string]any{{"timestamp": ts, "instanceId": "i-hk01", "Average": 8000}}
		case "diskusage_utilization":
			dps = []map[string]any{{"timestamp": ts, "instanceId": "i-hk01", "device": "/dev/vda1", "Average": 81.2}}
		}
		b, _ := json.Marshal(dps)
		write(200, map[string]any{"RequestId": "r", "Code": "200", "Period": "60", "Datapoints": string(b)})
	default:
		f.t.Errorf("unexpected action %q (%s)", action, r.URL.String())
		write(400, map[string]any{"Code": "InvalidAction"})
	}
}

func newTest(t *testing.T) (*Adapter, *fakeAli, providers.Account) {
	f := &fakeAli{t: t}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	return New(Options{Endpoint: strings.TrimPrefix(srv.URL, "http://"), Protocol: "http"}), f, providers.Account{
		ID: "a", Credentials: providers.Credentials{"access_key_id": "LTAI5tTEST", "access_key_secret": "secret"},
		Config: map[string]any{"regions": []any{"cn-hongkong"}}}
}

func TestDiscoverPaginatesAndMaps(t *testing.T) {
	a, _, acct := newTest(t)
	res, err := a.Discover(context.Background(), acct)
	if err != nil {
		t.Fatal(err)
	}
	if len(res) != 2 {
		t.Fatalf("expected 2 instances across pages, got %d", len(res))
	}
	if res[0].PowerState != model.PowerRunning || res[0].OSType != "linux" || res[0].Environment() != "production" || res[0].Region != "cn-hongkong" {
		t.Errorf("i-hk01 = %+v", res[0])
	}
	if res[1].PowerState != model.PowerStopped || res[1].OSType != "windows" {
		t.Errorf("i-hk02 = %+v", res[1])
	}
}

func TestMetricsAndAgentGaps(t *testing.T) {
	a, _, acct := newTest(t)
	now := time.Now()
	res, err := a.CollectMetrics(context.Background(), acct, []model.ResourceRef{
		{ID: "r1", ProviderResourceID: "i-hk01", Type: model.TypeVM, Region: "cn-hongkong", PowerState: model.PowerRunning},
	}, now.Add(-10*time.Minute), now)
	if err != nil {
		t.Fatal(err)
	}
	vals := map[string]float64{}
	for _, s := range res.Samples["r1"] {
		vals[s.Metric+s.Series] = s.Value
	}
	if vals["cpu.utilization"] != 37.5 || vals["net.in_bytes_per_sec"] != 1000 || vals["disk.utilizationmount=/dev/vda1"] != 81.2 {
		t.Errorf("values = %v", vals)
	}
	if !strings.Contains(res.Unavailable["r1"]["memory.utilization"], "CloudMonitor agent") {
		t.Errorf("agent-only metric without data must say so: %v", res.Unavailable["r1"])
	}
}

func TestHealthMapping(t *testing.T) {
	a, _, acct := newTest(t)
	obs, err := a.CollectHealth(context.Background(), acct, []model.ResourceRef{{ProviderResourceID: "i-hk01", Type: model.TypeVM, Region: "cn-hongkong"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(obs) != 1 || obs[0].Health != model.HealthUnavailable {
		t.Fatalf("Impaired must map to unavailable: %+v", obs)
	}
}

func TestErrorClassification(t *testing.T) {
	a, f, acct := newTest(t)
	f.throttle = true
	if _, err := a.Discover(context.Background(), acct); err == nil {
		t.Fatal("expected error")
	} else if _, ok := providers.IsThrottled(errors.Unwrap(err)); !ok {
		if _, ok2 := providers.IsThrottled(err); !ok2 {
			t.Errorf("Throttling.User must be classified as throttled: %v", err)
		}
	}
	f.throttle, f.badKey = false, true
	if _, err := a.Discover(context.Background(), acct); !errors.Is(err, providers.ErrInvalidCreds) {
		t.Errorf("InvalidAccessKeyId must be ErrInvalidCreds: %v", err)
	}
	rep, err := a.ValidateCredentials(context.Background(), acct)
	if err != nil || rep.OK {
		t.Errorf("validation must fail with a bad key: %+v %v", rep, err)
	}
}
