package azure

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/to"
	"github.com/Azure/azure-sdk-for-go/sdk/monitor/query/azlogs"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/monitor/armmonitor"
	"golang.org/x/sync/errgroup"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// metricMap maps one Azure Monitor platform metric to a normalized metric.
type metricMap struct {
	Native     string
	Agg        string // Average | Total | Maximum
	Normalized string
	// Scale converts the aggregated value; perInterval divides Totals by the interval
	// length in seconds to produce a per-second rate.
	Scale       float64
	PerInterval bool
	Optional    bool // requested separately; failure marks the metric unavailable only
}

// platformMetrics lists the Azure Monitor platform metrics Skywatch collects per type.
// Names are from the Azure Monitor supported-metrics reference for each namespace.
var platformMetrics = map[model.ResourceType][]metricMap{
	model.TypeVM: {
		{Native: "Percentage CPU", Agg: "Average", Normalized: "cpu.utilization"},
		{Native: "Available Memory Bytes", Agg: "Average", Normalized: "memory.available_bytes"},
		{Native: "Network In Total", Agg: "Total", Normalized: "net.in_bytes_per_sec", PerInterval: true},
		{Native: "Network Out Total", Agg: "Total", Normalized: "net.out_bytes_per_sec", PerInterval: true},
		{Native: "Disk Read Bytes", Agg: "Total", Normalized: "disk.read_bytes_per_sec", PerInterval: true},
		{Native: "Disk Write Bytes", Agg: "Total", Normalized: "disk.write_bytes_per_sec", PerInterval: true},
		{Native: "Disk Read Operations/Sec", Agg: "Average", Normalized: "disk.read_ops_per_sec"},
		{Native: "Disk Write Operations/Sec", Agg: "Average", Normalized: "disk.write_ops_per_sec"},
		{Native: "VmAvailabilityMetric", Agg: "Average", Normalized: "vm.availability", Optional: true},
	},
	model.TypeVMScaleSet: {
		{Native: "Percentage CPU", Agg: "Average", Normalized: "cpu.utilization"},
		{Native: "Network In Total", Agg: "Total", Normalized: "net.in_bytes_per_sec", PerInterval: true},
		{Native: "Network Out Total", Agg: "Total", Normalized: "net.out_bytes_per_sec", PerInterval: true},
	},
	model.TypeAppService: {
		{Native: "Http5xx", Agg: "Total", Normalized: "app.http_5xx"},
		{Native: "HttpResponseTime", Agg: "Average", Normalized: "app.response_time_ms", Scale: 1000},
	},
	model.TypeFunctionApp: {
		{Native: "Http5xx", Agg: "Total", Normalized: "app.http_5xx"},
	},
	model.TypeSQLDatabase: {
		{Native: "cpu_percent", Agg: "Average", Normalized: "db.cpu_utilization"},
		{Native: "storage_percent", Agg: "Maximum", Normalized: "db.storage_utilization"},
	},
	model.TypeStorageAccount: {
		{Native: "Availability", Agg: "Average", Normalized: "storage.availability"},
	},
	model.TypeLoadBalancer: {
		{Native: "VipAvailability", Agg: "Average", Normalized: "lb.data_path_availability"},
	},
	model.TypeAppGateway: {
		{Native: "HealthyHostCount", Agg: "Average", Normalized: "lb.healthy_backends"},
	},
	model.TypeFirewall: {
		{Native: "FirewallHealth", Agg: "Average", Normalized: "firewall.health"},
	},
	model.TypeK8sCluster: {
		{Native: "node_cpu_usage_percentage", Agg: "Average", Normalized: "cpu.utilization"},
		{Native: "node_memory_working_set_percentage", Agg: "Average", Normalized: "memory.utilization"},
	},
}

// CollectMetrics implements providers.Adapter.
func (a *Adapter) CollectMetrics(ctx context.Context, acct providers.Account, refs []model.ResourceRef, from, to time.Time) (*providers.MetricsResult, error) {
	cfg := parseConfig(acct)
	res := providers.NewMetricsResult()
	cred, err := a.credential(acct, cfg)
	if err != nil {
		return res, err
	}
	client, err := armmonitor.NewMetricsClient("", cred, a.armOptions(cfg))
	if err != nil {
		return res, err
	}

	var (
		mu        sync.Mutex
		throttled *providers.ThrottledError
		fatal     error
	)
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(a.opts.Concurrency)
	for _, ref := range refs {
		ref := ref
		maps := platformMetrics[ref.Type]
		if len(maps) == 0 {
			continue
		}
		if ref.PowerState.IsOff() {
			mu.Lock()
			for _, m := range maps {
				res.MarkUnavailable(ref.ID, m.Normalized, "resource is "+string(ref.PowerState))
			}
			mu.Unlock()
			continue
		}
		var core, optional []metricMap
		for _, m := range maps {
			if m.Optional {
				optional = append(optional, m)
			} else {
				core = append(core, m)
			}
		}
		groups := [][]metricMap{core}
		for _, o := range optional {
			groups = append(groups, []metricMap{o})
		}
		for _, grp := range groups {
			grp := grp
			if len(grp) == 0 {
				continue
			}
			g.Go(func() error {
				samples, err := a.fetchMetrics(gctx, client, ref.ProviderResourceID, grp, from, to)
				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					cerr := classify(err)
					if t, ok := providers.IsThrottled(cerr); ok {
						throttled = t
						return cerr // cancel remaining calls; we are being rate limited
					}
					if errors.Is(cerr, providers.ErrInvalidCreds) {
						fatal = cerr
						return cerr
					}
					for _, m := range grp {
						res.MarkUnavailable(ref.ID, m.Normalized, firstLine(cerr.Error()))
					}
					return nil
				}
				res.Add(ref.ID, samples...)
				for _, m := range grp {
					if !hasMetric(samples, m.Normalized) {
						res.MarkUnavailable(ref.ID, m.Normalized, "no datapoints returned by Azure Monitor for this interval")
					}
				}
				return nil
			})
		}
	}
	_ = g.Wait()
	if throttled != nil {
		return res, throttled
	}
	if fatal != nil {
		return res, fatal
	}

	// Guest metrics from VM Insights, when a workspace is configured.
	if len(cfg.WorkspaceIDs) > 0 {
		if err := a.collectGuestMetrics(ctx, acct, cfg, refs, from, to, res); err != nil {
			if t, ok := providers.IsThrottled(err); ok {
				return res, t
			}
			for _, ref := range refs {
				if ref.Type == model.TypeVM && !ref.PowerState.IsOff() {
					res.MarkUnavailable(ref.ID, "disk.utilization", "Log Analytics query failed: "+firstLine(err.Error()))
				}
			}
		}
	} else {
		for _, ref := range refs {
			if ref.Type == model.TypeVM {
				res.MarkUnavailable(ref.ID, "disk.utilization", "requires the Skywatch agent or VM Insights with a configured Log Analytics workspace")
				res.MarkUnavailable(ref.ID, "memory.utilization", "Azure platform metrics expose available memory only; utilization requires a guest agent")
			}
		}
	}
	return res, nil
}

func hasMetric(s []model.Sample, metric string) bool {
	for _, x := range s {
		if x.Metric == metric {
			return true
		}
	}
	return false
}

func (a *Adapter) fetchMetrics(ctx context.Context, client *armmonitor.MetricsClient, resourceID string, maps []metricMap, from, to time.Time) ([]model.Sample, error) {
	names := make([]string, len(maps))
	aggs := map[string]bool{}
	byNative := map[string]metricMap{}
	for i, m := range maps {
		names[i] = m.Native
		aggs[m.Agg] = true
		byNative[strings.ToLower(m.Native)] = m
	}
	aggList := make([]string, 0, len(aggs))
	for k := range aggs {
		aggList = append(aggList, k)
	}
	resp, err := client.List(ctx, resourceID, &armmonitor.MetricsClientListOptions{
		Timespan:    toPtr(from.UTC().Format(time.RFC3339) + "/" + to.UTC().Format(time.RFC3339)),
		Interval:    toPtr("PT1M"),
		Metricnames: toPtr(strings.Join(names, ",")),
		Aggregation: toPtr(strings.Join(aggList, ",")),
	})
	if err != nil {
		return nil, err
	}
	return convertMetrics(resp.Response, byNative, 60), nil
}

func toPtr(s string) *string { return to.Ptr(s) }

// convertMetrics converts an Azure Monitor metrics response into normalized samples.
func convertMetrics(resp armmonitor.Response, byNative map[string]metricMap, intervalSec float64) []model.Sample {
	var out []model.Sample
	for _, m := range resp.Value {
		if m == nil || m.Name == nil || m.Name.Value == nil {
			continue
		}
		mm, ok := byNative[strings.ToLower(*m.Name.Value)]
		if !ok {
			continue
		}
		for _, ts := range m.Timeseries {
			if ts == nil {
				continue
			}
			for _, d := range ts.Data {
				if d == nil || d.TimeStamp == nil {
					continue
				}
				var v *float64
				switch mm.Agg {
				case "Average":
					v = d.Average
				case "Total":
					v = d.Total
				case "Maximum":
					v = d.Maximum
				}
				if v == nil {
					continue // Azure returns null for minutes without data; never invent zeros
				}
				val := *v
				if mm.PerInterval {
					val = val / intervalSec
				}
				if mm.Scale != 0 {
					val = val * mm.Scale
				}
				out = append(out, model.Sample{Metric: mm.Normalized, TS: d.TimeStamp.UTC(), Value: val})
			}
		}
	}
	return out
}

// guestMetricsQuery reads VM Insights performance data (Azure Monitor Agent with the
// VM Insights data collection rule) from InsightsMetrics.
const guestMetricsQuery = `InsightsMetrics
| where TimeGenerated between (datetime(%s) .. datetime(%s))
| where Origin == "vm.azm.ms"
| where (Namespace == "LogicalDisk" and Name == "FreeSpacePercentage") or (Namespace == "Memory" and Name == "AvailableMB")
| extend t = parse_json(Tags)
| extend mount = tostring(t["vm.azm.ms/mountId"]), diskSizeMB = todouble(t["vm.azm.ms/diskSizeMB"]), memSizeMB = todouble(t["vm.azm.ms/memorySizeMB"])
| summarize Val = avg(Val), diskSizeMB = max(diskSizeMB), memSizeMB = max(memSizeMB)
    by rid = tolower(_ResourceId), Namespace, Name, mount, TimeGenerated = bin(TimeGenerated, 1m)`

func (a *Adapter) collectGuestMetrics(ctx context.Context, acct providers.Account, cfg accountConfig, refs []model.ResourceRef, from, to time.Time, res *providers.MetricsResult) error {
	byRID := map[string]string{}
	for _, r := range refs {
		if r.Type == model.TypeVM {
			byRID[strings.ToLower(r.ProviderResourceID)] = r.ID
		}
	}
	if len(byRID) == 0 {
		return nil
	}
	cred, err := a.credential(acct, cfg)
	if err != nil {
		return err
	}
	client, err := azlogs.NewClient(cred, a.logsOptions(cfg))
	if err != nil {
		return err
	}
	q := fmt.Sprintf(guestMetricsQuery, from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339))
	seen := map[string]bool{}
	for _, ws := range cfg.WorkspaceIDs {
		resp, err := client.QueryWorkspace(ctx, ws, azlogs.QueryBody{Query: &q}, nil)
		if err != nil {
			return classify(err)
		}
		for _, row := range tableRows(resp.Tables) {
			id, ok := byRID[asString(row["rid"])]
			if !ok {
				continue
			}
			seen[id] = true
			ts, err := time.Parse(time.RFC3339Nano, asString(row["TimeGenerated"]))
			if err != nil {
				continue
			}
			val := asFloat(row["Val"])
			switch asString(row["Namespace"]) + "/" + asString(row["Name"]) {
			case "LogicalDisk/FreeSpacePercentage":
				series := "mount=" + asString(row["mount"])
				res.Add(id, model.Sample{Metric: "disk.utilization", Series: series, TS: ts, Value: 100 - val})
				if size := asFloat(row["diskSizeMB"]); size > 0 {
					total := size * 1024 * 1024
					res.Add(id,
						model.Sample{Metric: "disk.total_bytes", Series: series, TS: ts, Value: total},
						model.Sample{Metric: "disk.used_bytes", Series: series, TS: ts, Value: total * (100 - val) / 100})
				}
			case "Memory/AvailableMB":
				avail := val * 1024 * 1024
				res.Add(id, model.Sample{Metric: "memory.available_bytes", TS: ts, Value: avail})
				if size := asFloat(row["memSizeMB"]); size > 0 {
					total := size * 1024 * 1024
					res.Add(id,
						model.Sample{Metric: "memory.total_bytes", TS: ts, Value: total},
						model.Sample{Metric: "memory.utilization", TS: ts, Value: 100 * (1 - avail/total)})
				}
			}
		}
	}
	for rid, id := range byRID {
		_ = rid
		if !seen[id] {
			res.MarkUnavailable(id, "disk.utilization", "no VM Insights data in the configured workspace (is Azure Monitor Agent with VM Insights enabled?)")
		}
	}
	return nil
}

// tableRows converts azlogs tables to column-name keyed rows.
func tableRows(tables []azlogs.Table) []map[string]any {
	var out []map[string]any
	for _, t := range tables {
		for _, r := range t.Rows {
			m := make(map[string]any, len(t.Columns))
			for i, c := range t.Columns {
				if i < len(r) && c.Name != nil {
					m[*c.Name] = r[i]
				}
			}
			out = append(out, m)
		}
	}
	return out
}

func asString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}

func asFloat(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case int64:
		return float64(t)
	case int:
		return float64(t)
	}
	return 0
}
