// Package digitalocean implements the DigitalOcean adapter with the official godo
// client: Droplets, Load Balancers, Managed Databases, Kubernetes and Volumes for
// inventory, and the Monitoring API (/v2/monitoring/metrics/droplet/*) for metrics.
//
// Droplet CPU, bandwidth and disk I/O come from the hypervisor. Memory, filesystem and
// load metrics require the DigitalOcean metrics agent (do-agent) inside the Droplet;
// when it is missing the API returns empty results and Skywatch reports the metric as
// unavailable with that reason rather than showing zeros.
package digitalocean

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/digitalocean/godo"
	"github.com/digitalocean/godo/metrics"
	"golang.org/x/sync/errgroup"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// Options customise the adapter.
type Options struct {
	BaseURL     string       // override API base (contract tests)
	HTTPClient  *http.Client // override transport (contract tests)
	Concurrency int
}

// Adapter implements providers.Adapter.
type Adapter struct{ opts Options }

// New returns a DigitalOcean adapter.
func New(opts Options) *Adapter {
	if opts.Concurrency <= 0 {
		opts.Concurrency = 4 // DO allows 5,000 requests/hour per token; stay conservative
	}
	return &Adapter{opts: opts}
}

// Provider implements providers.Adapter.
func (a *Adapter) Provider() model.Provider { return model.ProviderDigitalOcean }

// statsTransport counts API calls and 429s.
type statsTransport struct{ base http.RoundTripper }

func (t statsTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	st := providers.StatsFrom(r.Context())
	st.AddCall()
	resp, err := t.base.RoundTrip(r)
	if resp != nil && resp.StatusCode == http.StatusTooManyRequests {
		st.AddThrottled()
	}
	return resp, err
}

func (a *Adapter) client(acct providers.Account) (*godo.Client, error) {
	tok := acct.Credentials["token"]
	if tok == "" {
		return nil, fmt.Errorf("%w: API token is required", providers.ErrInvalidCreds)
	}
	hc := a.opts.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: 30 * time.Second}
	}
	base := hc.Transport
	if base == nil {
		base = http.DefaultTransport
	}
	wrapped := &http.Client{Timeout: hc.Timeout, Transport: statsTransport{base: authTransport{tok: tok, base: base}}}
	opts := []godo.ClientOpt{godo.SetUserAgent("skywatch-monitor")}
	if a.opts.BaseURL != "" {
		opts = append(opts, godo.SetBaseURL(a.opts.BaseURL))
	}
	return godo.New(wrapped, opts...)
}

type authTransport struct {
	tok  string
	base http.RoundTripper
}

func (t authTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+t.tok)
	return t.base.RoundTrip(r)
}

// classify maps godo errors to platform error classes.
func classify(err error) error {
	if err == nil {
		return nil
	}
	var er *godo.ErrorResponse
	if errors.As(err, &er) && er.Response != nil {
		switch er.Response.StatusCode {
		case http.StatusUnauthorized:
			return fmt.Errorf("%w: %s", providers.ErrInvalidCreds, er.Message)
		case http.StatusForbidden:
			return fmt.Errorf("%w: %s", providers.ErrForbidden, er.Message)
		case http.StatusTooManyRequests:
			wait := time.Minute
			if reset := er.Response.Header.Get("RateLimit-Reset"); reset != "" {
				if ts, err := strconv.ParseInt(reset, 10, 64); err == nil {
					if d := time.Until(time.Unix(ts, 0)); d > 0 {
						wait = d
					}
				}
			}
			return &providers.ThrottledError{RetryAfter: wait, Detail: er.Message}
		}
	}
	return err
}

// Capabilities implements providers.Adapter.
func (a *Adapter) Capabilities() []providers.Capability {
	return []providers.Capability{
		{Key: "auth.token", Title: "Personal access token (read-only custom scopes)", Status: providers.Implemented},
		{Key: "discovery", Title: "Droplets, Load Balancers, Managed Databases, Kubernetes, Volumes", Status: providers.Implemented,
			ResourceType: []string{"vm", "load_balancer", "managed_database", "kubernetes_cluster", "volume"}},
		{Key: "power_state", Title: "Droplet status (new/active/off/archive)", Status: providers.Implemented},
		{Key: "platform_metrics", Title: "Droplet CPU, bandwidth (Monitoring API)", Status: providers.Implemented,
			Notes: "Bandwidth values are interpreted as Mbps (as shown in DigitalOcean graphs); confirm during live verification."},
		{Key: "guest_metrics", Title: "Memory, filesystem usage, load", Status: providers.Implemented,
			Requires: []string{"DigitalOcean metrics agent (do-agent) installed in the Droplet"}},
		{Key: "provider_health", Title: "Per-resource provider health", Status: providers.Unsupported,
			Notes: "DigitalOcean exposes no per-resource health API; use the Skywatch agent and synthetic checks."},
		{Key: "guest_heartbeat", Title: "Guest heartbeat", Status: providers.Unsupported, Notes: "Use the Skywatch agent."},
		{Key: "activity_events", Title: "Droplet action history", Status: providers.Implemented},
		{Key: "lb_metrics", Title: "Load balancer metrics", Status: providers.NotImplemented},
		{Key: "db_metrics", Title: "Managed database metrics", Status: providers.NotImplemented},
	}
}

// MetricSupport implements providers.Adapter.
func (a *Adapter) MetricSupport() []providers.MetricSupport {
	return []providers.MetricSupport{
		{ResourceType: model.TypeVM, Metric: "cpu.utilization", NativeMetric: "droplet/cpu (mode counters)"},
		{ResourceType: model.TypeVM, Metric: "net.in_bytes_per_sec", NativeMetric: "droplet/bandwidth public inbound", Notes: "Mbps converted to bytes/s"},
		{ResourceType: model.TypeVM, Metric: "net.out_bytes_per_sec", NativeMetric: "droplet/bandwidth public outbound", Notes: "Mbps converted to bytes/s"},
		{ResourceType: model.TypeVM, Metric: "memory.utilization", NativeMetric: "droplet/memory_total, memory_available", RequiresAgent: true},
		{ResourceType: model.TypeVM, Metric: "disk.utilization", NativeMetric: "droplet/filesystem_size, filesystem_free", RequiresAgent: true},
		{ResourceType: model.TypeVM, Metric: "cpu.load1", NativeMetric: "droplet/load_1", RequiresAgent: true},
	}
}

// ValidateCredentials implements providers.Adapter.
func (a *Adapter) ValidateCredentials(ctx context.Context, acct providers.Account) (*providers.ValidationReport, error) {
	rep := &providers.ValidationReport{ValidatedAt: time.Now().UTC()}
	c, err := a.client(acct)
	if err != nil {
		rep.Checks = append(rep.Checks, providers.PermissionCheck{Check: "API token present", Detail: err.Error()})
		return rep, nil
	}
	check := func(name, scope string, fn func() error) bool {
		err := classify(fn())
		pc := providers.PermissionCheck{Check: name, OK: err == nil}
		if err != nil {
			pc.Detail = err.Error()
			pc.Missing = "token scope " + scope
		}
		rep.Checks = append(rep.Checks, pc)
		return err == nil
	}
	check("Read account", "account:read", func() error {
		acc, _, err := c.Account.Get(ctx)
		if err == nil {
			rep.Identity = acc.Email
			if acc.Team != nil {
				rep.Scopes = append(rep.Scopes, "Team "+acc.Team.Name)
			}
		}
		return err
	})
	var probe int
	check("List Droplets", "droplet:read", func() error {
		ds, _, err := c.Droplets.List(ctx, &godo.ListOptions{PerPage: 1})
		if len(ds) > 0 {
			probe = ds[0].ID
		}
		return err
	})
	check("Read monitoring metrics", "monitoring:read", func() error {
		if probe == 0 {
			return nil
		}
		now := time.Now()
		_, _, err := c.Monitoring.GetDropletCPU(ctx, &godo.DropletMetricsRequest{HostID: strconv.Itoa(probe), Start: now.Add(-10 * time.Minute), End: now})
		return err
	})
	check("List Load Balancers", "load_balancer:read", func() error { _, _, err := c.LoadBalancers.List(ctx, &godo.ListOptions{PerPage: 1}); return err })
	check("List Managed Databases", "database:read", func() error { _, _, err := c.Databases.List(ctx, &godo.ListOptions{PerPage: 1}); return err })
	check("List Kubernetes clusters", "kubernetes:read", func() error { _, _, err := c.Kubernetes.List(ctx, &godo.ListOptions{PerPage: 1}); return err })
	check("List Volumes", "block_storage:read", func() error {
		_, _, err := c.Storage.ListVolumes(ctx, &godo.ListVolumeParams{ListOptions: &godo.ListOptions{PerPage: 1}})
		return err
	})
	rep.OK = true
	for _, ch := range rep.Checks {
		if !ch.OK {
			rep.OK = false
		}
	}
	return rep, nil
}

func dropletPower(status string) model.PowerState {
	switch status {
	case "active":
		return model.PowerRunning
	case "off", "archive":
		return model.PowerStopped
	case "new":
		return model.PowerProvisioning
	}
	return model.PowerUnknown
}

func tags(ts []string) map[string]string {
	m := map[string]string{}
	for _, t := range ts {
		// DO tags are flat strings; "env:prod" style tags are split for scope matching.
		if k, v, ok := strings.Cut(t, ":"); ok {
			m[k] = v
		} else {
			m[t] = ""
		}
	}
	return m
}

func paginate(fn func(opt *godo.ListOptions) (*godo.Response, error)) error {
	opt := &godo.ListOptions{PerPage: 200}
	for page := 0; page < 100; page++ {
		resp, err := fn(opt)
		if err != nil {
			return classify(err)
		}
		if resp == nil || resp.Links == nil || resp.Links.IsLastPage() {
			return nil
		}
		p, err := resp.Links.CurrentPage()
		if err != nil {
			return err
		}
		opt.Page = p + 1
	}
	return nil
}

// Discover implements providers.Adapter.
func (a *Adapter) Discover(ctx context.Context, acct providers.Account) ([]model.DiscoveredResource, error) {
	c, err := a.client(acct)
	if err != nil {
		return nil, err
	}
	var out []model.DiscoveredResource
	dropletID := func(id int) string { return strconv.Itoa(id) }
	err = paginate(func(opt *godo.ListOptions) (*godo.Response, error) {
		ds, resp, err := c.Droplets.List(ctx, opt)
		for _, d := range ds {
			r := model.DiscoveredResource{ProviderResourceID: dropletID(d.ID), ExternalAccountID: acct.ExternalID, Name: d.Name,
				Type: model.TypeVM, NativeType: "droplet", Tags: tags(d.Tags), ProviderStateRaw: d.Status, PowerState: dropletPower(d.Status),
				OSType: "linux", Config: map[string]any{"size": d.SizeSlug, "vcpus": d.Vcpus, "memory_mb": d.Memory, "disk_gb": d.Disk}}
			if d.Region != nil {
				r.Region = d.Region.Slug
			}
			if d.Image != nil {
				r.OSName = strings.TrimSpace(d.Image.Distribution + " " + d.Image.Name)
			}
			out = append(out, r)
		}
		return resp, err
	})
	if err != nil {
		return nil, fmt.Errorf("list droplets: %w", err)
	}
	err = paginate(func(opt *godo.ListOptions) (*godo.Response, error) {
		lbs, resp, err := c.LoadBalancers.List(ctx, opt)
		for _, lb := range lbs {
			r := model.DiscoveredResource{ProviderResourceID: "lb:" + lb.ID, ExternalAccountID: acct.ExternalID, Name: lb.Name,
				Type: model.TypeLoadBalancer, NativeType: "load_balancer", Tags: tags(lb.Tags), ProviderStateRaw: lb.Status,
				PowerState: map[string]model.PowerState{"active": model.PowerRunning, "new": model.PowerProvisioning}[lb.Status], Config: map[string]any{}}
			if r.PowerState == "" {
				r.PowerState = model.PowerUnknown
			}
			if lb.Region != nil {
				r.Region = lb.Region.Slug
			}
			out = append(out, r)
			// Droplets behind the load balancer.
			for _, id := range lb.DropletIDs {
				for i := range out {
					if out[i].ProviderResourceID == dropletID(id) {
						out[i].Relations = append(out[i].Relations, model.Relation{ToProviderResourceID: r.ProviderResourceID, Kind: "backend_of"})
					}
				}
			}
		}
		return resp, err
	})
	if err != nil {
		return nil, fmt.Errorf("list load balancers: %w", err)
	}
	// Optional resource kinds: a missing scope must not fail Droplet discovery.
	_ = paginate(func(opt *godo.ListOptions) (*godo.Response, error) {
		dbs, resp, err := c.Databases.List(ctx, opt)
		for _, db := range dbs {
			ps := model.PowerUnknown
			switch db.Status {
			case "online":
				ps = model.PowerRunning
			case "creating", "migrating", "resizing":
				ps = model.PowerProvisioning
			}
			out = append(out, model.DiscoveredResource{ProviderResourceID: "db:" + db.ID, ExternalAccountID: acct.ExternalID, Name: db.Name,
				Type: model.TypeManagedDB, NativeType: "database:" + db.EngineSlug, Region: db.RegionSlug, Tags: tags(db.Tags),
				ProviderStateRaw: db.Status, PowerState: ps, Config: map[string]any{"engine": db.EngineSlug, "version": db.VersionSlug}})
		}
		return resp, err
	})
	_ = paginate(func(opt *godo.ListOptions) (*godo.Response, error) {
		ks, resp, err := c.Kubernetes.List(ctx, opt)
		for _, k := range ks {
			state := ""
			if k.Status != nil {
				state = string(k.Status.State)
			}
			ps := model.PowerUnknown
			switch state {
			case "running":
				ps = model.PowerRunning
			case "provisioning", "upgrading":
				ps = model.PowerProvisioning
			case "degraded", "error":
				ps = model.PowerRunning
			}
			out = append(out, model.DiscoveredResource{ProviderResourceID: "k8s:" + k.ID, ExternalAccountID: acct.ExternalID, Name: k.Name,
				Type: model.TypeK8sCluster, NativeType: "kubernetes", Region: k.RegionSlug, Tags: tags(k.Tags), ProviderStateRaw: state,
				PowerState: ps, Config: map[string]any{"version": k.VersionSlug, "node_pools": len(k.NodePools)}})
		}
		return resp, err
	})
	_ = paginate(func(opt *godo.ListOptions) (*godo.Response, error) {
		vs, resp, err := c.Storage.ListVolumes(ctx, &godo.ListVolumeParams{ListOptions: opt})
		for _, v := range vs {
			r := model.DiscoveredResource{ProviderResourceID: "vol:" + v.ID, ExternalAccountID: acct.ExternalID, Name: v.Name,
				Type: model.TypeVolume, NativeType: "volume", Tags: tags(v.Tags), PowerState: model.PowerNotApplicable,
				Config: map[string]any{"size_gb": v.SizeGigaBytes, "filesystem": v.FilesystemType}}
			if v.Region != nil {
				r.Region = v.Region.Slug
			}
			for _, id := range v.DropletIDs {
				r.Relations = append(r.Relations, model.Relation{ToProviderResourceID: dropletID(id), Kind: "attached_to"})
			}
			out = append(out, r)
		}
		return resp, err
	})
	return out, nil
}

// cpuUtilization converts per-mode cumulative CPU-seconds counters into utilization
// percentages between consecutive points: 100 * (1 - Δidle / Δtotal).
func cpuUtilization(streams []metrics.SampleStream) []model.Sample {
	idle := map[int64]float64{}
	total := map[int64]float64{}
	var ts []int64
	for _, s := range streams {
		mode := string(s.Metric["mode"])
		for _, v := range s.Values {
			t := v.Timestamp.Time().Unix()
			if _, ok := total[t]; !ok {
				ts = append(ts, t)
			}
			total[t] += float64(v.Value)
			if mode == "idle" {
				idle[t] += float64(v.Value)
			}
		}
	}
	sortInt64(ts)
	var out []model.Sample
	for i := 1; i < len(ts); i++ {
		dt := total[ts[i]] - total[ts[i-1]]
		di := idle[ts[i]] - idle[ts[i-1]]
		if dt <= 0 || di < 0 {
			continue // counter reset (reboot) or missing data
		}
		u := 100 * (1 - di/dt)
		if u < 0 {
			u = 0
		}
		out = append(out, model.Sample{Metric: "cpu.utilization", TS: time.Unix(ts[i], 0).UTC(), Value: u})
	}
	return out
}

func sortInt64(a []int64) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j] < a[j-1]; j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}

func points(streams []metrics.SampleStream, label string) map[string]map[int64]float64 {
	out := map[string]map[int64]float64{}
	for _, s := range streams {
		key := ""
		if label != "" {
			key = string(s.Metric[metrics.LabelName(label)])
		}
		if out[key] == nil {
			out[key] = map[int64]float64{}
		}
		for _, v := range s.Values {
			out[key][v.Timestamp.Time().Unix()] = float64(v.Value)
		}
	}
	return out
}

// CollectMetrics implements providers.Adapter.
func (a *Adapter) CollectMetrics(ctx context.Context, acct providers.Account, refs []model.ResourceRef, from, to time.Time) (*providers.MetricsResult, error) {
	res := providers.NewMetricsResult()
	c, err := a.client(acct)
	if err != nil {
		return res, err
	}
	var mu sync.Mutex
	var fatal error
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(a.opts.Concurrency)
	for _, ref := range refs {
		ref := ref
		if ref.Type != model.TypeVM {
			continue
		}
		if ref.PowerState.IsOff() {
			mu.Lock()
			res.MarkUnavailable(ref.ID, "cpu.utilization", "droplet is off")
			mu.Unlock()
			continue
		}
		g.Go(func() error {
			samples, gaps, err := a.dropletMetrics(gctx, c, ref.ProviderResourceID, from, to)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				err = classify(err)
				var t *providers.ThrottledError
				if errors.As(err, &t) || errors.Is(err, providers.ErrInvalidCreds) || errors.Is(err, providers.ErrForbidden) {
					fatal = err
					return err
				}
				res.MarkUnavailable(ref.ID, "cpu.utilization", err.Error())
				return nil
			}
			res.Add(ref.ID, samples...)
			for m, why := range gaps {
				res.MarkUnavailable(ref.ID, m, why)
			}
			return nil
		})
	}
	_ = g.Wait()
	return res, fatal
}

const noAgent = "DigitalOcean metrics agent (do-agent) not installed or not reporting on this Droplet"

func (a *Adapter) dropletMetrics(ctx context.Context, c *godo.Client, id string, from, to time.Time) ([]model.Sample, map[string]string, error) {
	req := &godo.DropletMetricsRequest{HostID: id, Start: from, End: to}
	gaps := map[string]string{}
	var out []model.Sample

	cpu, _, err := c.Monitoring.GetDropletCPU(ctx, req)
	if err != nil {
		return nil, nil, err
	}
	if s := cpuUtilization(cpu.Data.Result); len(s) > 0 {
		out = append(out, s...)
	} else {
		gaps["cpu.utilization"] = "no CPU datapoints returned for this interval"
	}
	for _, dir := range []struct{ direction, metric string }{{"inbound", "net.in_bytes_per_sec"}, {"outbound", "net.out_bytes_per_sec"}} {
		bw, _, err := c.Monitoring.GetDropletBandwidth(ctx, &godo.DropletBandwidthMetricsRequest{DropletMetricsRequest: *req, Interface: "public", Direction: dir.direction})
		if err != nil {
			return nil, nil, err
		}
		for _, series := range points(bw.Data.Result, "") {
			for t, mbps := range series {
				out = append(out, model.Sample{Metric: dir.metric, TS: time.Unix(t, 0).UTC(), Value: mbps * 1e6 / 8})
			}
		}
	}

	// Agent-dependent metrics.
	total, _, err1 := c.Monitoring.GetDropletTotalMemory(ctx, req)
	avail, _, err2 := c.Monitoring.GetDropletAvailableMemory(ctx, req)
	if err1 == nil && err2 == nil && len(total.Data.Result) > 0 && len(avail.Data.Result) > 0 {
		tp, ap := points(total.Data.Result, "")[""], points(avail.Data.Result, "")[""]
		for t, tot := range tp {
			if av, ok := ap[t]; ok && tot > 0 {
				ts := time.Unix(t, 0).UTC()
				out = append(out,
					model.Sample{Metric: "memory.total_bytes", TS: ts, Value: tot},
					model.Sample{Metric: "memory.available_bytes", TS: ts, Value: av},
					model.Sample{Metric: "memory.utilization", TS: ts, Value: 100 * (1 - av/tot)})
			}
		}
	} else {
		gaps["memory.utilization"] = noAgent
	}
	size, _, err1 := c.Monitoring.GetDropletFilesystemSize(ctx, req)
	free, _, err2 := c.Monitoring.GetDropletFilesystemFree(ctx, req)
	if err1 == nil && err2 == nil && len(size.Data.Result) > 0 {
		sp, fp := points(size.Data.Result, "mountpoint"), points(free.Data.Result, "mountpoint")
		for mount, series := range sp {
			for t, sz := range series {
				fr, ok := fp[mount][t]
				if !ok || sz <= 0 {
					continue
				}
				ts, s := time.Unix(t, 0).UTC(), "mount="+mount
				out = append(out,
					model.Sample{Metric: "disk.total_bytes", Series: s, TS: ts, Value: sz},
					model.Sample{Metric: "disk.free_bytes", Series: s, TS: ts, Value: fr},
					model.Sample{Metric: "disk.used_bytes", Series: s, TS: ts, Value: sz - fr},
					model.Sample{Metric: "disk.utilization", Series: s, TS: ts, Value: 100 * (sz - fr) / sz})
			}
		}
	} else {
		gaps["disk.utilization"] = noAgent
	}
	if load, _, err := c.Monitoring.GetDropletLoad1(ctx, req); err == nil {
		for t, v := range points(load.Data.Result, "")[""] {
			out = append(out, model.Sample{Metric: "cpu.load1", TS: time.Unix(t, 0).UTC(), Value: v})
		}
	}
	return out, gaps, nil
}

// CollectHealth implements providers.Adapter.
func (a *Adapter) CollectHealth(context.Context, providers.Account, []model.ResourceRef) ([]model.HealthObservation, error) {
	return nil, providers.ErrNotSupported
}

// CollectHeartbeats implements providers.Adapter.
func (a *Adapter) CollectHeartbeats(context.Context, providers.Account, time.Time) ([]model.HeartbeatObservation, error) {
	return nil, providers.ErrNotSupported
}

// CollectEvents implements providers.Adapter using the account action history
// (power cycles, resizes, rebuilds...).
func (a *Adapter) CollectEvents(ctx context.Context, acct providers.Account, since time.Time) ([]model.Event, error) {
	c, err := a.client(acct)
	if err != nil {
		return nil, err
	}
	actions, _, err := c.Actions.List(ctx, &godo.ListOptions{PerPage: 100})
	if err != nil {
		return nil, classify(err)
	}
	var out []model.Event
	for _, ac := range actions {
		if ac.StartedAt == nil || ac.StartedAt.Time.Before(since) {
			continue
		}
		sev := "info"
		if ac.Status == "errored" {
			sev = "error"
		}
		rid := ""
		if ac.ResourceType == "droplet" {
			rid = strconv.Itoa(ac.ResourceID)
		}
		out = append(out, model.Event{ProviderResourceID: rid, ExternalID: "action:" + strconv.Itoa(ac.ID),
			Kind: "do_action:" + ac.Type, Severity: sev, At: ac.StartedAt.Time.UTC(),
			Message: fmt.Sprintf("%s %s %d: %s", ac.Type, ac.ResourceType, ac.ResourceID, ac.Status)})
	}
	return out, nil
}
