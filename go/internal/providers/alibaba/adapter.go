// Package alibaba implements the Alibaba Cloud adapter with the official SDKs:
//
//   - ECS 2014-05-26 DescribeInstances            discovery and power state
//   - ECS 2014-05-26 DescribeInstancesFullStatus  provider health (HealthStatus)
//   - CloudMonitor 2019-01-01 DescribeMetricList  metrics (namespace acs_ecs_dashboard)
//
// Basic ECS metrics (CPUUtilization, network, disk I/O) are collected by the
// hypervisor. Memory, filesystem usage and load require the CloudMonitor agent inside
// the instance; when absent Skywatch reports those metrics as unavailable.
package alibaba

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	cms "github.com/alibabacloud-go/cms-20190101/v9/client"
	openapi "github.com/alibabacloud-go/darabonba-openapi/v2/client"
	ecs "github.com/alibabacloud-go/ecs-20140526/v7/client"
	"github.com/alibabacloud-go/tea/dara"
	"github.com/alibabacloud-go/tea/tea"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// Options customise the adapter.
type Options struct {
	// Endpoint overrides both ECS and CloudMonitor endpoints (contract tests).
	Endpoint string
	Protocol string
}

// Adapter implements providers.Adapter.
type Adapter struct{ opts Options }

// New returns an Alibaba Cloud adapter.
func New(opts Options) *Adapter { return &Adapter{opts: opts} }

// Provider implements providers.Adapter.
func (a *Adapter) Provider() model.Provider { return model.ProviderAlibaba }

func regions(acct providers.Account) []string {
	var out []string
	if list, ok := acct.Config["regions"].([]any); ok {
		for _, r := range list {
			if s, ok := r.(string); ok && s != "" {
				out = append(out, s)
			}
		}
	}
	return out
}

func (a *Adapter) config(acct providers.Account, region string) (*openapi.Config, error) {
	id, secret := acct.Credentials["access_key_id"], acct.Credentials["access_key_secret"]
	if id == "" || secret == "" {
		return nil, fmt.Errorf("%w: access_key_id and access_key_secret are required", providers.ErrInvalidCreds)
	}
	c := &openapi.Config{AccessKeyId: tea.String(id), AccessKeySecret: tea.String(secret), RegionId: tea.String(region),
		ReadTimeout: tea.Int(20000), ConnectTimeout: tea.Int(5000)}
	if tok := acct.Credentials["security_token"]; tok != "" {
		c.SecurityToken = tea.String(tok)
	}
	if a.opts.Endpoint != "" {
		c.Endpoint = tea.String(a.opts.Endpoint)
	}
	if a.opts.Protocol != "" {
		c.Protocol = tea.String(a.opts.Protocol)
	}
	return c, nil
}

func (a *Adapter) ecsClient(acct providers.Account, region string) (*ecs.Client, error) {
	c, err := a.config(acct, region)
	if err != nil {
		return nil, err
	}
	if a.opts.Endpoint == "" {
		c.Endpoint = tea.String("ecs." + region + ".aliyuncs.com")
	}
	return ecs.NewClient(c)
}

func (a *Adapter) cmsClient(acct providers.Account, region string) (*cms.Client, error) {
	c, err := a.config(acct, region)
	if err != nil {
		return nil, err
	}
	if a.opts.Endpoint == "" {
		c.Endpoint = tea.String("metrics." + region + ".aliyuncs.com")
	}
	return cms.NewClient(c)
}

// classify maps SDK errors (tea.SDKError) onto platform error classes.
func classify(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	code, status, msg := "", 0, err.Error()
	var se *tea.SDKError
	if errors.As(err, &se) {
		code, msg = tea.StringValue(se.Code), tea.StringValue(se.Message)
		status = tea.IntValue(se.StatusCode)
	}
	var de *dara.SDKError
	if errors.As(err, &de) {
		code, msg = tea.StringValue(de.Code), tea.StringValue(de.Message)
		status = tea.IntValue(de.StatusCode)
	}
	switch {
	case strings.HasPrefix(code, "Throttling") || status == http.StatusTooManyRequests:
		providers.StatsFrom(ctx).AddThrottled()
		return &providers.ThrottledError{RetryAfter: time.Minute, Detail: code}
	case strings.HasPrefix(code, "InvalidAccessKeyId") || code == "SignatureDoesNotMatch" || code == "InvalidSecurityToken.Expired" || status == http.StatusUnauthorized:
		return fmt.Errorf("%w: %s", providers.ErrInvalidCreds, code)
	case code == "Forbidden.RAM" || strings.HasPrefix(code, "Forbidden") || code == "NoPermission" || status == http.StatusForbidden:
		return fmt.Errorf("%w: %s", providers.ErrForbidden, code)
	}
	return fmt.Errorf("alibaba cloud API error %s: %s", code, firstLine(msg))
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i > 0 {
		return s[:i]
	}
	return s
}

func rt() *dara.RuntimeOptions {
	return &dara.RuntimeOptions{Autoretry: tea.Bool(true), MaxAttempts: tea.Int(2)}
}

// Capabilities implements providers.Adapter.
func (a *Adapter) Capabilities() []providers.Capability {
	return []providers.Capability{
		{Key: "auth.access_key", Title: "RAM user AccessKey (read-only policy)", Status: providers.Implemented},
		{Key: "auth.sts", Title: "STS token (AssumeRole)", Status: providers.Experimental,
			Notes: "Short-lived token supplied with the AccessKey; automatic re-assumption is not implemented."},
		{Key: "discovery.ecs", Title: "ECS instance discovery (multi-region)", Status: providers.Implemented, ResourceType: []string{"vm"}},
		{Key: "power_state", Title: "ECS instance status", Status: providers.Implemented},
		{Key: "provider_health", Title: "ECS HealthStatus (DescribeInstancesFullStatus)", Status: providers.Implemented},
		{Key: "platform_metrics", Title: "CloudMonitor basic ECS metrics (CPU, network, disk I/O)", Status: providers.Implemented},
		{Key: "guest_metrics", Title: "Memory, filesystem usage, load (CloudMonitor agent)", Status: providers.Experimental,
			Requires: []string{"CloudMonitor agent installed in the instance"},
			Notes:    "Filesystem series are keyed by the device reported by CloudMonitor."},
		{Key: "discovery.rds", Title: "ApsaraDB RDS discovery", Status: providers.NotImplemented},
		{Key: "discovery.slb", Title: "Server Load Balancer discovery", Status: providers.NotImplemented},
		{Key: "discovery.oss", Title: "Object Storage Service discovery", Status: providers.NotImplemented},
		{Key: "activity_events", Title: "ActionTrail events", Status: providers.NotImplemented},
		{Key: "guest_heartbeat", Title: "Guest heartbeat", Status: providers.Unsupported, Notes: "Use the Skywatch agent."},
	}
}

type metricDef struct {
	native, normalized string
	scale              float64
	agent              bool
}

var ecsMetrics = []metricDef{
	{native: "CPUUtilization", normalized: "cpu.utilization", scale: 1},
	{native: "InternetInRate", normalized: "net.in_bytes_per_sec", scale: 1.0 / 8},   // bit/s
	{native: "InternetOutRate", normalized: "net.out_bytes_per_sec", scale: 1.0 / 8}, // bit/s
	{native: "DiskReadBPS", normalized: "disk.read_bytes_per_sec", scale: 1},
	{native: "DiskWriteBPS", normalized: "disk.write_bytes_per_sec", scale: 1},
	{native: "DiskReadIOPS", normalized: "disk.read_ops_per_sec", scale: 1},
	{native: "DiskWriteIOPS", normalized: "disk.write_ops_per_sec", scale: 1},
	{native: "memory_usedutilization", normalized: "memory.utilization", scale: 1, agent: true},
	{native: "diskusage_utilization", normalized: "disk.utilization", scale: 1, agent: true},
	{native: "load_1m", normalized: "cpu.load1", scale: 1, agent: true},
}

// MetricSupport implements providers.Adapter.
func (a *Adapter) MetricSupport() []providers.MetricSupport {
	var out []providers.MetricSupport
	for _, m := range ecsMetrics {
		out = append(out, providers.MetricSupport{ResourceType: model.TypeVM, Metric: m.normalized, NativeMetric: "acs_ecs_dashboard/" + m.native, RequiresAgent: m.agent})
	}
	return out
}

// ValidateCredentials implements providers.Adapter.
func (a *Adapter) ValidateCredentials(ctx context.Context, acct providers.Account) (*providers.ValidationReport, error) {
	rep := &providers.ValidationReport{ValidatedAt: time.Now().UTC()}
	regs := regions(acct)
	if len(regs) == 0 {
		rep.Checks = append(rep.Checks, providers.PermissionCheck{Check: "Regions configured", Missing: "Select at least one region to monitor"})
		return rep, nil
	}
	rep.OK = true
	for _, region := range regs {
		c, err := a.ecsClient(acct, region)
		if err == nil {
			_, err = c.DescribeInstancesWithContext(ctx, (&ecs.DescribeInstancesRequest{}).SetRegionId(region).SetMaxResults(1), rt())
		}
		pc := providers.PermissionCheck{Check: "ecs:DescribeInstances in " + region, OK: err == nil}
		if err != nil {
			pc.Detail, pc.Missing = classify(ctx, err).Error(), "RAM policy action ecs:DescribeInstances"
			rep.OK = false
		} else {
			rep.Scopes = append(rep.Scopes, region)
		}
		rep.Checks = append(rep.Checks, pc)
		mc, err := a.cmsClient(acct, region)
		if err == nil {
			now := time.Now()
			_, err = mc.DescribeMetricList(&cms.DescribeMetricListRequest{Namespace: tea.String("acs_ecs_dashboard"), MetricName: tea.String("CPUUtilization"),
				Period: tea.String("60"), StartTime: tea.String(msString(now.Add(-5 * time.Minute))), EndTime: tea.String(msString(now)), Length: tea.String("1")})
		}
		pc = providers.PermissionCheck{Check: "cms:DescribeMetricList in " + region, OK: err == nil}
		if err != nil {
			pc.Detail, pc.Missing = classify(ctx, err).Error(), "RAM policy action cms:DescribeMetricList"
			rep.OK = false
		}
		rep.Checks = append(rep.Checks, pc)
	}
	rep.Identity = acct.Credentials["access_key_id"]
	return rep, nil
}

func msString(t time.Time) string { return strconv.FormatInt(t.UnixMilli(), 10) }

func powerState(status string) model.PowerState {
	switch status {
	case "Running":
		return model.PowerRunning
	case "Stopped":
		return model.PowerStopped
	case "Starting":
		return model.PowerStarting
	case "Stopping":
		return model.PowerStopping
	case "Pending":
		return model.PowerProvisioning
	}
	return model.PowerUnknown
}

// Discover implements providers.Adapter.
func (a *Adapter) Discover(ctx context.Context, acct providers.Account) ([]model.DiscoveredResource, error) {
	regs := regions(acct)
	if len(regs) == 0 {
		return nil, errors.New("no regions configured for this Alibaba Cloud account")
	}
	var out []model.DiscoveredResource
	for _, region := range regs {
		c, err := a.ecsClient(acct, region)
		if err != nil {
			return nil, err
		}
		req := (&ecs.DescribeInstancesRequest{}).SetRegionId(region).SetMaxResults(100)
		for page := 0; page < 500; page++ {
			providers.StatsFrom(ctx).AddCall()
			resp, err := c.DescribeInstancesWithContext(ctx, req, rt())
			if err != nil {
				return nil, fmt.Errorf("DescribeInstances %s: %w", region, classify(ctx, err))
			}
			body := resp.Body
			if body == nil || body.Instances == nil {
				break
			}
			for _, in := range body.Instances.Instance {
				d := model.DiscoveredResource{
					ProviderResourceID: tea.StringValue(in.InstanceId), ExternalAccountID: acct.ExternalID,
					Name: tea.StringValue(in.InstanceName), Type: model.TypeVM, NativeType: "ecs:instance",
					Region: tea.StringValue(in.RegionId), ProviderStateRaw: tea.StringValue(in.Status),
					PowerState: powerState(tea.StringValue(in.Status)), OSName: tea.StringValue(in.OSName),
					Tags: map[string]string{}, Config: map[string]any{"instance_type": tea.StringValue(in.InstanceType),
						"zone": tea.StringValue(in.ZoneId), "cpu": tea.Int32Value(in.Cpu), "memory_mb": tea.Int32Value(in.Memory)},
				}
				switch strings.ToLower(tea.StringValue(in.OSType)) {
				case "linux":
					d.OSType = "linux"
				case "windows":
					d.OSType = "windows"
				}
				if in.Tags != nil {
					for _, t := range in.Tags.Tag {
						d.Tags[tea.StringValue(t.TagKey)] = tea.StringValue(t.TagValue)
					}
				}
				if d.Name == "" {
					d.Name = d.ProviderResourceID
				}
				out = append(out, d)
			}
			next := tea.StringValue(body.NextToken)
			if next == "" {
				break
			}
			req.SetNextToken(next)
		}
	}
	return out, nil
}

type datapoint map[string]any

func (d datapoint) float(k string) (float64, bool) {
	switch v := d[k].(type) {
	case float64:
		return v, true
	case string:
		f, err := strconv.ParseFloat(v, 64)
		return f, err == nil
	}
	return 0, false
}

// CollectMetrics implements providers.Adapter. Instances are queried in batches of 50
// per metric (CloudMonitor accepts a JSON array of instance dimensions).
func (a *Adapter) CollectMetrics(ctx context.Context, acct providers.Account, refs []model.ResourceRef, from, to time.Time) (*providers.MetricsResult, error) {
	res := providers.NewMetricsResult()
	byRegion := map[string][]model.ResourceRef{}
	idMap := map[string]string{}
	for _, r := range refs {
		if r.Type != model.TypeVM {
			continue
		}
		if r.PowerState.IsOff() {
			res.MarkUnavailable(r.ID, "cpu.utilization", "instance is stopped")
			continue
		}
		byRegion[r.Region] = append(byRegion[r.Region], r)
		idMap[r.ProviderResourceID] = r.ID
	}
	for region, rs := range byRegion {
		c, err := a.cmsClient(acct, region)
		if err != nil {
			return res, err
		}
		for start := 0; start < len(rs); start += 50 {
			batch := rs[start:min(start+50, len(rs))]
			dims := make([]map[string]string, len(batch))
			for i, r := range batch {
				dims[i] = map[string]string{"instanceId": r.ProviderResourceID}
			}
			dimJSON, _ := json.Marshal(dims)
			for _, m := range ecsMetrics {
				seen := map[string]bool{}
				next := ""
				for page := 0; page < 20; page++ {
					req := &cms.DescribeMetricListRequest{Namespace: tea.String("acs_ecs_dashboard"), MetricName: tea.String(m.native),
						Period: tea.String("60"), StartTime: tea.String(msString(from)), EndTime: tea.String(msString(to)),
						Dimensions: tea.String(string(dimJSON)), Length: tea.String("1000")}
					if next != "" {
						req.NextToken = tea.String(next)
					}
					providers.StatsFrom(ctx).AddCall()
					resp, err := c.DescribeMetricList(req)
					if err != nil {
						cerr := classify(ctx, err)
						if _, ok := providers.IsThrottled(cerr); ok || errors.Is(cerr, providers.ErrInvalidCreds) {
							return res, cerr
						}
						for _, r := range batch {
							res.MarkUnavailable(r.ID, m.normalized, cerr.Error())
						}
						break
					}
					if resp.Body == nil {
						break
					}
					if code := tea.StringValue(resp.Body.Code); code != "" && code != "200" {
						for _, r := range batch {
							res.MarkUnavailable(r.ID, m.normalized, "CloudMonitor: "+tea.StringValue(resp.Body.Message))
						}
						break
					}
					var dps []datapoint
					_ = json.Unmarshal([]byte(tea.StringValue(resp.Body.Datapoints)), &dps)
					for _, dp := range dps {
						iid, _ := dp["instanceId"].(string)
						rid, ok := idMap[iid]
						if !ok {
							continue
						}
						v, ok := dp.float("Average")
						if !ok {
							continue
						}
						tsMs, _ := dp.float("timestamp")
						series := ""
						if m.normalized == "disk.utilization" {
							mount, _ := dp["mountpoint"].(string)
							if mount == "" {
								mount, _ = dp["device"].(string)
							}
							series = "mount=" + mount
						}
						res.Add(rid, model.Sample{Metric: m.normalized, Series: series, TS: time.UnixMilli(int64(tsMs)).UTC(), Value: v * m.scale})
						seen[rid] = true
					}
					next = tea.StringValue(resp.Body.NextToken)
					if next == "" {
						break
					}
				}
				for _, r := range batch {
					if !seen[r.ID] && res.Unavailable[r.ID][m.normalized] == "" {
						why := "no datapoints returned by CloudMonitor for this interval"
						if m.agent {
							why = "CloudMonitor agent not installed or not reporting on this instance"
						}
						res.MarkUnavailable(r.ID, m.normalized, why)
					}
				}
			}
		}
	}
	return res, nil
}

// CollectHealth implements providers.Adapter using DescribeInstancesFullStatus.
func (a *Adapter) CollectHealth(ctx context.Context, acct providers.Account, refs []model.ResourceRef) ([]model.HealthObservation, error) {
	byRegion := map[string][]string{}
	for _, r := range refs {
		if r.Type == model.TypeVM {
			byRegion[r.Region] = append(byRegion[r.Region], r.ProviderResourceID)
		}
	}
	var out []model.HealthObservation
	for region, ids := range byRegion {
		c, err := a.ecsClient(acct, region)
		if err != nil {
			return out, err
		}
		for start := 0; start < len(ids); start += 100 {
			batch := ids[start:min(start+100, len(ids))]
			providers.StatsFrom(ctx).AddCall()
			resp, err := c.DescribeInstancesFullStatusWithContext(ctx, (&ecs.DescribeInstancesFullStatusRequest{}).
				SetRegionId(region).SetInstanceId(tea.StringSlice(batch)).SetPageSize(100), rt())
			if err != nil {
				return out, classify(ctx, err)
			}
			if resp.Body == nil || resp.Body.InstanceFullStatusSet == nil {
				continue
			}
			for _, s := range resp.Body.InstanceFullStatusSet.InstanceFullStatusType {
				name := ""
				if s.HealthStatus != nil {
					name = tea.StringValue(s.HealthStatus.Name)
				}
				h := model.HealthUnknown
				switch name {
				case "Ok":
					h = model.HealthAvailable
				case "Warning", "Maintaining":
					h = model.HealthDegraded
				case "Impaired":
					h = model.HealthUnavailable
				}
				out = append(out, model.HealthObservation{ProviderResourceID: tea.StringValue(s.InstanceId), Health: h,
					Reason: "ECS HealthStatus " + name, ObservedAt: time.Now().UTC()})
			}
		}
	}
	return out, nil
}

// CollectHeartbeats implements providers.Adapter.
func (a *Adapter) CollectHeartbeats(context.Context, providers.Account, time.Time) ([]model.HeartbeatObservation, error) {
	return nil, providers.ErrNotSupported
}

// CollectEvents implements providers.Adapter.
func (a *Adapter) CollectEvents(context.Context, providers.Account, time.Time) ([]model.Event, error) {
	return nil, providers.ErrNotSupported
}
