package agent

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	mrand "math/rand/v2"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// Agent is a running agent instance.
type Agent struct {
	Dir      string
	Cfg      *Config
	Log      *slog.Logger
	Services ServiceSource
	// RotateEvery rotates the agent secret periodically. Default 30 days.
	RotateEvery time.Duration

	mu        sync.Mutex
	state     *State
	remote    telemetry.AgentConfig
	client    *Client
	collector *Collector
	queue     *Queue
	started   time.Time
	hostSent  bool
	lastInv   time.Time
}

// Enroll exchanges an enrollment token for an identity and writes state.json.
func Enroll(ctx context.Context, dir string, cfg *Config, token string) (*State, error) {
	c, err := NewClient(cfg, nil)
	if err != nil {
		return nil, err
	}
	req := telemetry.EnrollRequest{EnrollmentToken: token, AgentVersion: Version, Host: HostInfo(ctx)}
	if !cfg.DisableCloudProbe {
		req.Cloud = DetectCloud(ctx)
	}
	var resp telemetry.EnrollResponse
	if err := c.Do(ctx, "POST", "/v1/agent/enroll", req, &resp); err != nil {
		if errors.Is(err, ErrUnauthorized) {
			return nil, errors.New("enrollment token invalid, expired, revoked or already used")
		}
		return nil, err
	}
	st := &State{AgentID: resp.AgentID, AgentSecret: resp.AgentSecret, ResourceID: resp.ResourceID, RotatedAt: time.Now().UTC()}
	if err := SaveConfig(dir, cfg); err != nil {
		return nil, err
	}
	return st, SaveState(dir, st)
}

func (a *Agent) authHeader() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.state == nil {
		return ""
	}
	return a.state.AgentID + "." + a.state.AgentSecret
}

// Run collects and ships telemetry until ctx is cancelled.
func (a *Agent) Run(ctx context.Context) error {
	st, err := LoadState(a.Dir)
	if err != nil {
		return fmt.Errorf("agent is not enrolled (run 'skywatch-agent enroll'): %w", err)
	}
	if a.RotateEvery == 0 {
		a.RotateEvery = 30 * 24 * time.Hour
	}
	a.state = st
	a.started = time.Now()
	a.queue = NewQueue(a.Cfg.QueueSize)
	a.collector = NewCollector(a.Cfg.ExcludeMounts)
	a.remote = telemetry.AgentConfig{HeartbeatIntervalSeconds: 60, MetricsIntervalSeconds: 60, DiscoverServices: true}
	if a.client, err = NewClient(a.Cfg, a.authHeader); err != nil {
		return err
	}
	if a.Services == nil {
		a.Services = NewServiceSource()
	}
	// Prime counters so the first batch has rates.
	a.collector.Collect(ctx)

	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); a.sender(ctx) }()
	a.Log.Info("agent started", "agent_id", st.AgentID, "version", Version)
	for {
		interval := time.Duration(a.interval()) * time.Second
		select {
		case <-ctx.Done():
			wg.Wait()
			return nil
		case <-time.After(interval):
		}
		a.queue.Push(a.buildBatch(ctx))
	}
}

func (a *Agent) interval() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.remote.HeartbeatIntervalSeconds < 10 {
		return 60
	}
	return a.remote.HeartbeatIntervalSeconds
}

func (a *Agent) buildBatch(ctx context.Context) telemetry.Batch {
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	metrics, partial := a.collector.Collect(cctx)
	a.mu.Lock()
	a.state.Seq++
	seq := a.state.Seq
	remote := a.remote
	a.mu.Unlock()

	b := telemetry.Batch{Version: telemetry.Version, BatchID: uuid.NewString(), Seq: seq, SentAt: time.Now().UTC(), Metrics: metrics, Partial: partial}
	if !a.hostSent || seq%60 == 0 {
		h := HostInfo(cctx)
		b.Host = &h
		a.hostSent = true
	}
	// Watched services every batch; full inventory every 15 minutes when enabled.
	watched := append(append([]string{}, remote.WatchedServices...), a.Cfg.ExtraServices...)
	sort.Strings(watched)
	if svcs, err := a.Services.Get(cctx, dedupe(watched)); err != nil {
		b.Partial = append(b.Partial, telemetry.PartialInfo{Collector: "services", Error: err.Error()})
	} else {
		b.Services = svcs
	}
	if remote.DiscoverServices && time.Since(a.lastInv) > 15*time.Minute {
		if inv, err := a.Services.Discover(cctx); err == nil {
			b.Services = mergeServices(b.Services, inv)
			a.lastInv = time.Now()
		}
	}
	cpu, rss := a.collector.SelfStats()
	b.Agent = telemetry.AgentHealth{Version: Version, QueueDepth: a.queue.Len(), DroppedBatches: a.queue.Dropped(),
		CPUPercent: math.Round(cpu*100) / 100, RSSBytes: rss, UptimeSeconds: int64(time.Since(a.started).Seconds())}
	return b
}

func dedupe(in []string) []string {
	var out []string
	for i, s := range in {
		if s != "" && (i == 0 || in[i-1] != s) {
			out = append(out, s)
		}
	}
	return out
}

func mergeServices(watched, inv []telemetry.Service) []telemetry.Service {
	seen := map[string]bool{}
	for _, s := range watched {
		seen[s.Name] = true
	}
	for _, s := range inv {
		if !seen[s.Name] && len(watched) < telemetry.MaxServices {
			watched = append(watched, s)
		}
	}
	return watched
}

// sender drains the queue in order with exponential backoff and jitter.
func (a *Agent) sender(ctx context.Context) {
	failures := 0
	lastPersist := time.Now()
	for ctx.Err() == nil {
		b, ok := a.queue.Peek()
		if !ok {
			sleep(ctx, time.Second)
			continue
		}
		var ack telemetry.BatchAck
		err := a.client.Do(ctx, "POST", "/v1/agent/telemetry", b, &ack)
		var perm *PermanentError
		var ra *RetryAfterError
		switch {
		case err == nil:
			a.queue.Pop(b.BatchID)
			failures = 0
			a.mu.Lock()
			a.remote = ack.Config
			a.mu.Unlock()
			if time.Since(lastPersist) > 5*time.Minute {
				a.persist()
				lastPersist = time.Now()
			}
			a.maybeRotate(ctx)
			continue
		case errors.As(err, &perm):
			a.Log.Error("batch rejected by server; dropping it", "batch", b.BatchID, "err", err)
			a.queue.Pop(b.BatchID)
			continue
		case errors.Is(err, ErrUnauthorized):
			a.Log.Error("agent credential rejected: the agent may have been revoked or re-enrolled elsewhere; re-enroll to resume")
			sleep(ctx, 5*time.Minute)
			continue
		case errors.As(err, &ra):
			sleep(ctx, ra.After)
			continue
		}
		failures++
		d := backoff(failures)
		a.Log.Warn("telemetry upload failed; retrying", "err", err, "retry_in", d.Round(time.Second), "queued", a.queue.Len())
		sleep(ctx, d)
	}
	a.persist()
}

func (a *Agent) persist() {
	a.mu.Lock()
	st := *a.state
	a.mu.Unlock()
	if err := SaveState(a.Dir, &st); err != nil {
		a.Log.Warn("persist state", "err", err)
	}
}

func (a *Agent) maybeRotate(ctx context.Context) {
	a.mu.Lock()
	due := time.Since(a.state.RotatedAt) > a.RotateEvery
	a.mu.Unlock()
	if !due {
		return
	}
	var rr telemetry.RotateResponse
	if err := a.client.Do(ctx, "POST", "/v1/agent/rotate", map[string]any{}, &rr); err != nil {
		a.Log.Warn("secret rotation failed; will retry", "err", err)
		return
	}
	a.mu.Lock()
	a.state.AgentSecret = rr.AgentSecret
	a.state.RotatedAt = time.Now().UTC()
	a.mu.Unlock()
	a.persist()
	a.Log.Info("agent secret rotated")
}

func backoff(failures int) time.Duration {
	d := time.Duration(math.Min(300, math.Pow(2, float64(failures)))) * time.Second
	return d/2 + time.Duration(mrand.Int64N(int64(d/2)+1))
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
