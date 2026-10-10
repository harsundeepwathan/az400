package azure

// Mocked contract tests for the Azure adapter. A TLS test server stands in for Azure
// Resource Manager, Resource Graph, Azure Monitor and Log Analytics. Fixtures follow the
// documented REST response shapes; the assertions pin the request contract (paths,
// api-versions, query parameters) that the official SDK sends. Live verification steps
// are in docs/LIVE_VERIFICATION.md.

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/cloud"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/monitor/query/azlogs"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

type fakeCred struct{}

func (fakeCred) GetToken(context.Context, policy.TokenRequestOptions) (azcore.AccessToken, error) {
	return azcore.AccessToken{Token: "test-token", ExpiresOn: time.Now().Add(time.Hour)}, nil
}

const (
	sub   = "11111111-1111-1111-1111-111111111111"
	vm1   = "/subscriptions/" + sub + "/resourcegroups/rg-prod/providers/microsoft.compute/virtualmachines/web-01"
	vm2   = "/subscriptions/" + sub + "/resourcegroups/rg-prod/providers/microsoft.compute/virtualmachines/batch-02"
	lb1   = "/subscriptions/" + sub + "/resourcegroups/rg-prod/providers/microsoft.network/loadbalancers/lb-web"
	wsID  = "22222222-2222-2222-2222-222222222222"
	vmRaw = "/subscriptions/" + sub + "/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/web-01"
)

type fakeAzure struct {
	t        *testing.T
	mu       sync.Mutex
	requests []string
	// knobs
	activityStatus int
	metricsStatus  int
}

func (f *fakeAzure) record(r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, r.Method+" "+r.URL.Path+"?"+r.URL.RawQuery)
}

func (f *fakeAzure) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.record(r)
	if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
		f.t.Errorf("missing bearer token on %s: %q", r.URL.Path, got)
	}
	w.Header().Set("Content-Type", "application/json")
	p := r.URL.Path
	q := r.URL.Query()
	switch {
	case r.Method == http.MethodPost && p == "/providers/Microsoft.ResourceGraph/resources":
		if q.Get("api-version") != "2024-04-01" {
			f.t.Errorf("resource graph api-version = %q", q.Get("api-version"))
		}
		body, _ := io.ReadAll(r.Body)
		var req map[string]any
		_ = json.Unmarshal(body, &req)
		query, _ := req["query"].(string)
		opts, _ := req["options"].(map[string]any)
		switch {
		case strings.Contains(query, "resourcecontainers"):
			writeJSON(w, graphPage([]map[string]any{{"subscriptionId": sub, "name": "Production", "state": "Enabled"}}, ""))
		case strings.Contains(query, "networkinterfaces"):
			writeJSON(w, graphPage([]map[string]any{{"vmId": vm1, "poolId": lb1 + "/backendaddresspools/web-pool"}}, ""))
		default:
			if subs, _ := req["subscriptions"].([]any); len(subs) != 1 || subs[0] != sub {
				f.t.Errorf("inventory query not scoped to configured subscription: %v", req["subscriptions"])
			}
			if opts["$skipToken"] == nil {
				writeJSON(w, graphPage([]map[string]any{
					{"id": vmRaw, "name": "web-01", "type": "Microsoft.Compute/virtualMachines", "location": "westeurope",
						"resourceGroup": "rg-prod", "subscriptionId": sub, "tags": map[string]any{"environment": "production", "team": "web"},
						"powerState": "PowerState/running", "osType": "Linux", "osName": "ubuntu", "vmSize": "Standard_D2s_v5", "provisioningState": "Succeeded", "vmId": "aaaa"},
					{"id": vm2, "name": "batch-02", "type": "microsoft.compute/virtualmachines", "location": "westeurope",
						"resourceGroup": "rg-prod", "subscriptionId": sub, "tags": map[string]any{},
						"powerState": "PowerState/deallocated", "osType": "Windows", "provisioningState": "Succeeded"},
				}, "page-2-token"))
				return
			}
			if opts["$skipToken"] != "page-2-token" {
				f.t.Errorf("unexpected skip token %v", opts["$skipToken"])
			}
			writeJSON(w, graphPage([]map[string]any{
				{"id": lb1, "name": "lb-web", "type": "microsoft.network/loadbalancers", "location": "westeurope",
					"resourceGroup": "rg-prod", "subscriptionId": sub, "provisioningState": "Succeeded", "sku": map[string]any{"name": "Standard"}},
				{"id": "/subscriptions/" + sub + "/resourcegroups/rg-prod/providers/microsoft.web/sites/fn-orders", "name": "fn-orders",
					"type": "microsoft.web/sites", "kind": "functionapp,linux", "location": "westeurope", "resourceGroup": "rg-prod",
					"subscriptionId": sub, "siteState": "Stopped"},
				{"id": "/subscriptions/" + sub + "/resourcegroups/rg-prod/providers/microsoft.unknown/things/x", "name": "x",
					"type": "microsoft.unknown/things"},
			}, ""))
		}
	case strings.HasSuffix(p, "/providers/Microsoft.Insights/metrics"):
		if q.Get("api-version") != "2024-02-01" || q.Get("interval") != "PT1M" || q.Get("timespan") == "" {
			f.t.Errorf("metrics query contract violated: %s", r.URL.RawQuery)
		}
		if f.metricsStatus == http.StatusTooManyRequests {
			w.Header().Set("Retry-After", "17")
			w.WriteHeader(http.StatusTooManyRequests)
			writeJSON(w, map[string]any{"error": map[string]any{"code": "TooManyRequests", "message": "throttled"}})
			return
		}
		names := q.Get("metricnames")
		if strings.Contains(names, "VmAvailabilityMetric") {
			w.WriteHeader(http.StatusBadRequest)
			writeJSON(w, map[string]any{"error": map[string]any{"code": "BadRequest", "message": "Failed to find metric configuration for provider: Microsoft.Compute, resource Type: virtualMachines, metric: VmAvailabilityMetric"}})
			return
		}
		if !strings.Contains(names, "Percentage CPU") || !strings.Contains(q.Get("aggregation"), "Average") {
			f.t.Errorf("unexpected metric request: %s", r.URL.RawQuery)
		}
		writeJSON(w, map[string]any{
			"timespan": q.Get("timespan"), "interval": "PT1M", "namespace": "Microsoft.Compute/virtualMachines",
			"value": []any{
				metricJSON("Percentage CPU", []map[string]any{
					{"timeStamp": "2026-10-10T10:00:00Z", "average": 41.5},
					{"timeStamp": "2026-10-10T10:01:00Z", "average": nil},
					{"timeStamp": "2026-10-10T10:02:00Z", "average": 97.25},
				}),
				metricJSON("Network In Total", []map[string]any{{"timeStamp": "2026-10-10T10:00:00Z", "total": 6000.0}}),
				metricJSON("Available Memory Bytes", []map[string]any{}),
			},
		})
	case strings.HasSuffix(p, "/providers/Microsoft.ResourceHealth/availabilityStatuses"):
		writeJSON(w, map[string]any{"value": []any{
			map[string]any{"id": vmRaw + "/providers/Microsoft.ResourceHealth/availabilityStatuses/current", "name": "current",
				"properties": map[string]any{"availabilityState": "Unavailable", "summary": "The virtual machine is unavailable due to a host failure.", "reasonType": "Unplanned"}},
			map[string]any{"id": lb1 + "/providers/Microsoft.ResourceHealth/availabilityStatuses/current", "name": "current",
				"properties": map[string]any{"availabilityState": "Available", "summary": "There aren't any known Azure platform problems affecting this resource."}},
		}})
	case strings.HasSuffix(p, "/providers/Microsoft.Insights/eventtypes/management/values"):
		if f.activityStatus != 0 {
			w.WriteHeader(f.activityStatus)
			writeJSON(w, map[string]any{"error": map[string]any{"code": "AuthorizationFailed", "message": "no access"}})
			return
		}
		if !strings.Contains(q.Get("$filter"), "eventTimestamp ge") {
			f.t.Errorf("activity log filter missing: %s", r.URL.RawQuery)
		}
		writeJSON(w, map[string]any{"value": []any{
			map[string]any{"eventDataId": "ev-1", "eventTimestamp": "2026-10-10T09:58:00Z", "level": "Informational",
				"operationName": map[string]any{"value": "Microsoft.Compute/virtualMachines/deallocate/action", "localizedValue": "Deallocate Virtual Machine"},
				"status":        map[string]any{"value": "Succeeded", "localizedValue": "Succeeded"}, "category": map[string]any{"value": "Administrative"},
				"resourceId": vmRaw, "caller": "ops@contoso.example"},
			map[string]any{"eventDataId": "ev-2", "eventTimestamp": "2026-10-10T09:59:00Z", "level": "Informational",
				"operationName": map[string]any{"value": "Microsoft.Compute/virtualMachines/read"},
				"status":        map[string]any{"value": "Succeeded"}, "category": map[string]any{"value": "Administrative"}, "resourceId": vmRaw},
		}})
	case r.Method == http.MethodPost && p == "/v1/workspaces/"+wsID+"/query":
		body, _ := io.ReadAll(r.Body)
		switch {
		case strings.Contains(string(body), "InsightsMetrics"):
			writeJSON(w, map[string]any{"tables": []any{map[string]any{"name": "PrimaryResult",
				"columns": cols("rid", "Namespace", "Name", "mount", "TimeGenerated", "Val", "diskSizeMB", "memSizeMB"),
				"rows": []any{
					[]any{vm1, "LogicalDisk", "FreeSpacePercentage", "/", "2026-10-10T10:00:00Z", 12.0, 30720.0, nil},
					[]any{vm1, "LogicalDisk", "FreeSpacePercentage", "/data", "2026-10-10T10:00:00Z", 55.0, 102400.0, nil},
					[]any{vm1, "Memory", "AvailableMB", "", "2026-10-10T10:00:00Z", 1024.0, nil, 8192.0},
				}}}})
		default:
			writeJSON(w, map[string]any{"tables": []any{map[string]any{"name": "PrimaryResult",
				"columns": cols("rid", "Computer", "Category", "LastHeartbeat"),
				"rows":    []any{[]any{vm1, "web-01", "Azure Monitor Agent", "2026-10-10T10:03:12Z"}}}}})
		}
	default:
		f.t.Errorf("unexpected request %s %s", r.Method, r.URL.String())
		w.WriteHeader(http.StatusNotFound)
	}
}

func cols(names ...string) []any {
	out := make([]any, len(names))
	for i, n := range names {
		out[i] = map[string]any{"name": n, "type": "string"}
	}
	return out
}

func metricJSON(name string, data []map[string]any) map[string]any {
	return map[string]any{
		"id": "x", "type": "Microsoft.Insights/metrics", "unit": "Percent", "errorCode": "Success",
		"name":       map[string]any{"value": name, "localizedValue": name},
		"timeseries": []any{map[string]any{"metadatavalues": []any{}, "data": data}},
	}
}

func graphPage(rows []map[string]any, skip string) map[string]any {
	m := map[string]any{"totalRecords": len(rows), "count": len(rows), "resultTruncated": "false", "data": rows}
	if skip != "" {
		m["$skipToken"] = skip
	}
	return m
}

func writeJSON(w http.ResponseWriter, v any) { _ = json.NewEncoder(w).Encode(v) }

func newTestAdapter(t *testing.T) (*Adapter, *fakeAzure, providers.Account) {
	fa := &fakeAzure{t: t}
	srv := httptest.NewTLSServer(fa)
	t.Cleanup(srv.Close)
	cfg := cloud.Configuration{
		ActiveDirectoryAuthorityHost: srv.URL,
		Services: map[cloud.ServiceName]cloud.ServiceConfiguration{
			cloud.ResourceManager: {Endpoint: srv.URL, Audience: "https://management.azure.com"},
			azlogs.ServiceName:    {Endpoint: srv.URL, Audience: "https://api.loganalytics.io"},
		},
	}
	a := New(Options{Transport: srv.Client(), Cloud: &cfg, Credential: fakeCred{}, MaxRetries: -1})
	acct := providers.Account{
		ID: "acct-1", AuthMethod: AuthClientSecret,
		Credentials: providers.Credentials{"tenant_id": "t", "client_id": "c", "client_secret": "s"},
		Config: map[string]any{
			"subscription_ids":            []any{sub},
			"log_analytics_workspace_ids": []any{wsID},
		},
	}
	return a, fa, acct
}

func TestDiscoverMapsInventoryPowerStateAndRelations(t *testing.T) {
	a, _, acct := newTestAdapter(t)
	got, err := a.Discover(context.Background(), acct)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 4 {
		t.Fatalf("want 4 resources (unknown types dropped, pagination followed), got %d", len(got))
	}
	byName := map[string]model.DiscoveredResource{}
	for _, d := range got {
		byName[d.Name] = d
	}
	web := byName["web-01"]
	if web.ProviderResourceID != vm1 {
		t.Errorf("resource id not lower-cased: %s", web.ProviderResourceID)
	}
	if web.Type != model.TypeVM || web.PowerState != model.PowerRunning || web.OSType != "linux" || web.Environment() != "production" {
		t.Errorf("web-01 mapped incorrectly: %+v", web)
	}
	if len(web.Relations) != 1 || web.Relations[0].ToProviderResourceID != lb1 || web.Relations[0].Kind != "backend_of" {
		t.Errorf("expected backend_of relation to lb-web, got %+v", web.Relations)
	}
	if b := byName["batch-02"]; b.PowerState != model.PowerDeallocated || b.OSType != "windows" {
		t.Errorf("batch-02 mapped incorrectly: %+v", b)
	}
	if fn := byName["fn-orders"]; fn.Type != model.TypeFunctionApp || fn.PowerState != model.PowerStopped {
		t.Errorf("function app mapped incorrectly: %+v", fn)
	}
	if lb := byName["lb-web"]; lb.PowerState != model.PowerNotApplicable || lb.Type != model.TypeLoadBalancer {
		t.Errorf("lb mapped incorrectly: %+v", lb)
	}
}

func TestCollectMetricsNormalizesAndReportsGaps(t *testing.T) {
	a, _, acct := newTestAdapter(t)
	refs := []model.ResourceRef{
		{ID: "r-web", ProviderResourceID: vm1, Type: model.TypeVM, PowerState: model.PowerRunning},
		{ID: "r-batch", ProviderResourceID: vm2, Type: model.TypeVM, PowerState: model.PowerDeallocated},
	}
	from := time.Date(2026, 10, 10, 10, 0, 0, 0, time.UTC)
	stats := &providers.CallStats{}
	res, err := a.CollectMetrics(providers.WithStats(context.Background(), stats), acct, refs, from, from.Add(5*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	var cpu []float64
	var netIn float64
	disk := map[string]float64{}
	var memUtil float64
	for _, s := range res.Samples["r-web"] {
		switch s.Metric {
		case "cpu.utilization":
			cpu = append(cpu, s.Value)
		case "net.in_bytes_per_sec":
			netIn = s.Value
		case "disk.utilization":
			disk[s.Series] = s.Value
		case "memory.utilization":
			memUtil = s.Value
		}
	}
	if len(cpu) != 2 || cpu[0] != 41.5 || cpu[1] != 97.25 {
		t.Errorf("null datapoints must be skipped, not zero-filled: %v", cpu)
	}
	if netIn != 100 {
		t.Errorf("Network In Total (6000 bytes/min) should be 100 B/s, got %v", netIn)
	}
	if disk["mount=/"] != 88 || disk["mount=/data"] != 45 {
		t.Errorf("guest disk utilization from VM Insights wrong: %v", disk)
	}
	if memUtil != 87.5 {
		t.Errorf("memory utilization = %v, want 87.5", memUtil)
	}
	if res.Unavailable["r-web"]["vm.availability"] == "" {
		t.Errorf("unsupported optional metric must be reported as unavailable")
	}
	if res.Unavailable["r-web"]["memory.available_bytes"] == "" {
		t.Errorf("metric with no datapoints must be reported as unavailable")
	}
	if !strings.Contains(res.Unavailable["r-batch"]["cpu.utilization"], "deallocated") {
		t.Errorf("deallocated VM metrics must be marked unavailable: %v", res.Unavailable["r-batch"])
	}
	if len(res.Samples["r-batch"]) != 0 {
		t.Errorf("no metrics should be fetched for a deallocated VM")
	}
	if stats.Calls() < 3 {
		t.Errorf("call stats not recorded: %d", stats.Calls())
	}
}

func TestCollectMetricsSurfacesThrottling(t *testing.T) {
	a, fa, acct := newTestAdapter(t)
	fa.metricsStatus = http.StatusTooManyRequests
	stats := &providers.CallStats{}
	_, err := a.CollectMetrics(providers.WithStats(context.Background(), stats), acct,
		[]model.ResourceRef{{ID: "r", ProviderResourceID: vm1, Type: model.TypeVM, PowerState: model.PowerRunning}},
		time.Now().Add(-5*time.Minute), time.Now())
	te, ok := providers.IsThrottled(err)
	if !ok {
		t.Fatalf("expected ThrottledError, got %v", err)
	}
	if te.RetryAfter != 17*time.Second {
		t.Errorf("Retry-After not honoured: %v", te.RetryAfter)
	}
	if stats.Throttled() == 0 {
		t.Errorf("throttled responses not counted")
	}
}

func TestCollectHealthMapsResourceHealth(t *testing.T) {
	a, _, acct := newTestAdapter(t)
	obs, err := a.CollectHealth(context.Background(), acct, []model.ResourceRef{
		{ProviderResourceID: vm1}, {ProviderResourceID: lb1},
	})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]model.HealthObservation{}
	for _, o := range obs {
		got[o.ProviderResourceID] = o
	}
	if got[vm1].Health != model.HealthUnavailable || !strings.Contains(got[vm1].Reason, "Unplanned") {
		t.Errorf("vm health = %+v", got[vm1])
	}
	if got[lb1].Health != model.HealthAvailable {
		t.Errorf("lb health = %+v", got[lb1])
	}
}

func TestCollectHeartbeatsFromLogAnalytics(t *testing.T) {
	a, _, acct := newTestAdapter(t)
	hb, err := a.CollectHeartbeats(context.Background(), acct, time.Now().Add(-30*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if len(hb) != 1 || hb[0].ProviderResourceID != vm1 || hb[0].LastHeartbeat.Format(time.RFC3339) != "2026-10-10T10:03:12Z" {
		t.Fatalf("heartbeats = %+v", hb)
	}

	acct.Config = map[string]any{"subscription_ids": []any{sub}}
	if _, err := a.CollectHeartbeats(context.Background(), acct, time.Now()); !errors.Is(err, providers.ErrNotSupported) {
		t.Errorf("without a workspace heartbeats must be ErrNotSupported, got %v", err)
	}
}

func TestCollectEventsKeepsChangesDropsReads(t *testing.T) {
	a, _, acct := newTestAdapter(t)
	ev, err := a.CollectEvents(context.Background(), acct, time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(ev) != 1 || ev[0].ExternalID != "ev-1" || ev[0].ProviderResourceID != vm1 {
		t.Fatalf("events = %+v", ev)
	}
	if !strings.Contains(ev[0].Message, "Deallocate Virtual Machine") || !strings.Contains(ev[0].Message, "ops@contoso.example") {
		t.Errorf("event message = %q", ev[0].Message)
	}
}

func TestValidateCredentialsReportsMissingPermissions(t *testing.T) {
	a, fa, acct := newTestAdapter(t)
	fa.activityStatus = http.StatusForbidden
	rep, err := a.ValidateCredentials(context.Background(), acct)
	if err != nil {
		t.Fatal(err)
	}
	if rep.OK {
		t.Fatalf("report should fail when Activity Log is forbidden: %+v", rep)
	}
	var found bool
	for _, c := range rep.Checks {
		if c.Check == "Read Azure Activity Log" {
			found = true
			if c.OK || !strings.Contains(c.Missing, "Microsoft.Insights/eventtypes/values/read") {
				t.Errorf("activity log check = %+v", c)
			}
		}
	}
	if !found {
		t.Errorf("activity log check missing: %+v", rep.Checks)
	}
	fa.activityStatus = 0
	rep, _ = a.ValidateCredentials(context.Background(), acct)
	if !rep.OK || len(rep.Scopes) != 1 {
		t.Errorf("expected passing report, got %+v", rep)
	}
}

func TestClassifyErrors(t *testing.T) {
	mk := func(code int) error {
		req, _ := http.NewRequest(http.MethodGet, "https://management.azure.com/x", nil)
		return &azcore.ResponseError{StatusCode: code, ErrorCode: "X", RawResponse: &http.Response{StatusCode: code, Request: req, Header: http.Header{}}}
	}
	if !errors.Is(classify(mk(401)), providers.ErrInvalidCreds) {
		t.Error("401 should be ErrInvalidCreds")
	}
	if !errors.Is(classify(mk(403)), providers.ErrForbidden) {
		t.Error("403 should be ErrForbidden")
	}
	if _, ok := providers.IsThrottled(classify(mk(429))); !ok {
		t.Error("429 should be throttled")
	}
}

func TestBuildCredentialRejectsIncompleteSecrets(t *testing.T) {
	_, err := buildCredential(providers.Account{AuthMethod: AuthClientSecret, Credentials: providers.Credentials{"client_id": "x"}},
		accountConfig{TenantID: "t"}, azcore.ClientOptions{})
	if !errors.Is(err, providers.ErrInvalidCreds) {
		t.Fatalf("expected ErrInvalidCreds, got %v", err)
	}
}
