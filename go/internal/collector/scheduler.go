// Package collector runs provider collection jobs on a durable, database-backed schedule.
//
// Design:
//   - Jobs live in collection_jobs (one row per account × kind). Any number of collector
//     instances may run; jobs are claimed with FOR UPDATE SKIP LOCKED and a lease, so a
//     crashed instance's work is picked up once its lease expires.
//   - Each run is bounded by a timeout, concurrency is bounded by a semaphore, and the
//     next run time carries ±10% jitter so accounts do not synchronise.
//   - Failures back off exponentially (capped at 1h); throttling honours Retry-After.
//   - Collection failures degrade the *account* (status degraded/error) and never mark
//     customer resources down: the evaluator turns a degraded account into "Unknown /
//     Monitoring degraded" for resources without independent signals.
package collector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
	"github.com/harsundeepwathan/az400/go/internal/providers/demo"
	"github.com/harsundeepwathan/az400/go/internal/secrets"
	"github.com/harsundeepwathan/az400/go/internal/selfmon"
)

// Default intervals per job kind. Provider-specific minimums are enforced in
// DefaultIntervals so tenants cannot configure a schedule that would exhaust API quotas.
var DefaultIntervals = map[string]time.Duration{
	"discovery": 5 * time.Minute,
	"metrics":   2 * time.Minute,
	"health":    5 * time.Minute,
	"heartbeat": 2 * time.Minute,
	"events":    5 * time.Minute,
}

// Config for the scheduler.
type Config struct {
	InstanceID   string
	Concurrency  int
	PollInterval time.Duration
	JobTimeout   time.Duration
}

// Scheduler claims and runs due collection jobs.
type Scheduler struct {
	pool     *pgxpool.Pool
	keys     secrets.KeyProvider
	adapters map[model.Provider]providers.Adapter
	cfg      Config
	log      *slog.Logger
	now      func() time.Time
}

// New creates a scheduler.
func New(pool *pgxpool.Pool, keys secrets.KeyProvider, adapters []providers.Adapter, cfg Config, log *slog.Logger) *Scheduler {
	if cfg.Concurrency <= 0 {
		cfg.Concurrency = 8
	}
	if cfg.PollInterval <= 0 {
		cfg.PollInterval = 5 * time.Second
	}
	if cfg.JobTimeout <= 0 {
		cfg.JobTimeout = 4 * time.Minute
	}
	m := map[model.Provider]providers.Adapter{}
	for _, a := range adapters {
		m[a.Provider()] = a
	}
	return &Scheduler{pool: pool, keys: keys, adapters: m, cfg: cfg, log: log, now: time.Now}
}

// Adapter returns the adapter for a provider.
func (s *Scheduler) Adapter(p model.Provider) (providers.Adapter, bool) {
	a, ok := s.adapters[p]
	return a, ok
}

type job struct {
	ID          string
	OrgID       string
	AccountID   string
	Kind        string
	Interval    time.Duration
	Failures    int
	LastSuccess *time.Time
}

// Run loops until ctx is cancelled.
func (s *Scheduler) Run(ctx context.Context) error {
	sem := make(chan struct{}, s.cfg.Concurrency)
	t := time.NewTicker(s.cfg.PollInterval)
	defer t.Stop()
	ensureT := time.NewTicker(time.Minute)
	defer ensureT.Stop()
	if err := s.EnsureJobs(ctx); err != nil {
		s.log.Error("ensure jobs", "err", err)
	}
	for {
		free := cap(sem) - len(sem)
		if free > 0 {
			jobs, err := s.claim(ctx, free)
			if err != nil && ctx.Err() == nil {
				s.log.Error("claim jobs", "err", err)
			}
			for _, j := range jobs {
				sem <- struct{}{}
				go func(j job) {
					defer func() { <-sem }()
					s.runJob(ctx, j)
				}(j)
			}
		}
		select {
		case <-ctx.Done():
			// Drain: wait for in-flight jobs so leases are released cleanly.
			for i := 0; i < cap(sem); i++ {
				sem <- struct{}{}
			}
			return nil
		case <-ensureT.C:
			if err := s.EnsureJobs(ctx); err != nil {
				s.log.Error("ensure jobs", "err", err)
			}
		case <-t.C:
		}
	}
}

// EnsureJobs creates missing jobs for active accounts and removes jobs for disabled ones.
func (s *Scheduler) EnsureJobs(ctx context.Context) error {
	for kind, iv := range DefaultIntervals {
		_, err := s.pool.Exec(ctx, `
			INSERT INTO collection_jobs(org_id, cloud_account_id, kind, interval_seconds, next_run_at)
			SELECT a.org_id, a.id, $1, $2, now() + (random() * interval '20 seconds')
			FROM cloud_accounts a
			WHERE a.status IN ('active','degraded','error')
			ON CONFLICT (cloud_account_id, kind) DO NOTHING`, kind, int(iv.Seconds()))
		if err != nil {
			return err
		}
	}
	_, err := s.pool.Exec(ctx, `DELETE FROM collection_jobs j USING cloud_accounts a
		WHERE j.cloud_account_id = a.id AND a.status IN ('disabled','pending','validating')`)
	return err
}

func (s *Scheduler) claim(ctx context.Context, n int) ([]job, error) {
	rows, err := s.pool.Query(ctx, `
		UPDATE collection_jobs j
		SET lease_owner = $1, lease_expires_at = now() + $2::interval, last_started_at = now()
		WHERE j.id IN (
			SELECT id FROM collection_jobs
			WHERE next_run_at <= now() AND (lease_expires_at IS NULL OR lease_expires_at < now())
			ORDER BY next_run_at
			FOR UPDATE SKIP LOCKED
			LIMIT $3)
		RETURNING j.id, j.org_id, j.cloud_account_id, j.kind, j.interval_seconds, j.consecutive_failures,
		          (SELECT last_success_at FROM cloud_accounts WHERE id = j.cloud_account_id)`,
		s.cfg.InstanceID, fmt.Sprintf("%d seconds", int(s.cfg.JobTimeout.Seconds())+30), n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []job
	for rows.Next() {
		var j job
		var iv int
		if err := rows.Scan(&j.ID, &j.OrgID, &j.AccountID, &j.Kind, &iv, &j.Failures, &j.LastSuccess); err != nil {
			return nil, err
		}
		j.Interval = time.Duration(iv) * time.Second
		out = append(out, j)
	}
	return out, rows.Err()
}

// LoadAccount loads and decrypts an account.
func (s *Scheduler) LoadAccount(ctx context.Context, orgID, accountID string) (providers.Account, model.Provider, error) {
	var (
		acct     providers.Account
		provider string
		blob     []byte
		cfgJSON  []byte
	)
	err := s.pool.QueryRow(ctx, `SELECT id, org_id, provider, coalesce(external_id,''), auth_method, credential_ciphertext, config
		FROM cloud_accounts WHERE id=$1 AND org_id=$2`, accountID, orgID).
		Scan(&acct.ID, &acct.OrgID, &provider, &acct.ExternalID, &acct.AuthMethod, &blob, &cfgJSON)
	if err != nil {
		return acct, "", err
	}
	acct.Config = map[string]any{}
	_ = json.Unmarshal(cfgJSON, &acct.Config)
	acct.Credentials = providers.Credentials{}
	if len(blob) > 0 {
		pt, err := secrets.Open(ctx, s.keys, blob, secrets.CloudAccountAAD(orgID, accountID))
		if err != nil {
			return acct, model.Provider(provider), fmt.Errorf("%w: credential could not be decrypted", providers.ErrInvalidCreds)
		}
		if err := json.Unmarshal(pt, &acct.Credentials); err != nil {
			return acct, model.Provider(provider), fmt.Errorf("%w: credential document malformed", providers.ErrInvalidCreds)
		}
	}
	return acct, model.Provider(provider), nil
}

// RunResult summarises a job execution.
type RunResult struct {
	Items int
	// Partial is set when the run succeeded for some resources only.
	Partial bool
}

func (s *Scheduler) runJob(parent context.Context, j job) {
	ctx, cancel := context.WithTimeout(parent, s.cfg.JobTimeout)
	defer cancel()
	stats := &providers.CallStats{}
	ctx = providers.WithStats(ctx, stats)
	started := s.now()

	res, err := s.execute(ctx, j)
	finished := s.now()
	status := "ok"
	if res.Partial {
		status = "partial"
	}
	var errText *string
	next := finished.Add(jitter(j.Interval))
	failures := 0
	accountStatus, accountReason := "", ""

	if err != nil {
		e := err.Error()
		errText = &e
		failures = j.Failures + 1
		switch t, throttled := providers.IsThrottled(err); {
		case throttled:
			status = "throttled"
			wait := t.RetryAfter
			if b := backoff(j.Interval, failures); b > wait {
				wait = b
			}
			next = finished.Add(wait)
		case errors.Is(err, providers.ErrNotSupported):
			// Capability absent for this account (e.g. no Log Analytics workspace): not a failure.
			status, errText, failures = "skipped", nil, 0
			next = finished.Add(30 * time.Minute)
		case errors.Is(err, providers.ErrInvalidCreds):
			status = "error"
			next = finished.Add(backoff(j.Interval, failures))
			accountStatus, accountReason = "error", "Authentication failed: "+e
		case errors.Is(err, providers.ErrForbidden):
			status = "error"
			next = finished.Add(backoff(j.Interval, failures))
			accountStatus, accountReason = "degraded", "Permission denied: "+e
		default:
			status = "error"
			next = finished.Add(backoff(j.Interval, failures))
			if failures >= 3 {
				accountStatus, accountReason = "degraded", fmt.Sprintf("%s collection failing (%d consecutive): %s", j.Kind, failures, e)
			}
		}
		s.log.Warn("collection job failed", "kind", j.Kind, "account", j.AccountID, "status", status, "failures", failures, "err", err)
	}
	selfmon.CollectorRuns.WithLabelValues(j.Kind, status).Inc()
	selfmon.ProviderCalls.WithLabelValues(j.Kind).Add(float64(stats.Calls()))
	selfmon.ProviderThrottled.WithLabelValues(j.Kind).Add(float64(stats.Throttled()))
	selfmon.CollectorDuration.WithLabelValues(j.Kind).Observe(finished.Sub(started).Seconds())

	bg := context.Background() // record the outcome even if the parent is shutting down
	tx, txErr := s.pool.Begin(bg)
	if txErr != nil {
		s.log.Error("record job", "err", txErr)
		return
	}
	defer tx.Rollback(bg) //nolint:errcheck
	_, _ = tx.Exec(bg, `UPDATE collection_jobs SET lease_owner=NULL, lease_expires_at=NULL, last_finished_at=$2,
		last_status=$3, last_error=$4, last_duration_ms=$5, consecutive_failures=$6, next_run_at=$7 WHERE id=$1`,
		j.ID, finished, status, errText, finished.Sub(started).Milliseconds(), failures, next)
	_, _ = tx.Exec(bg, `INSERT INTO collector_runs(org_id, job_id, cloud_account_id, kind, instance_id, started_at, finished_at,
		status, error, api_calls, throttled_calls, items) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
		j.OrgID, j.ID, j.AccountID, j.Kind, s.cfg.InstanceID, started, finished, status, errText, stats.Calls(), stats.Throttled(), res.Items)
	if stats.Throttled() > 0 {
		_, _ = tx.Exec(bg, `UPDATE cloud_accounts SET throttle_events = throttle_events + $2, last_throttled_at = now() WHERE id=$1`,
			j.AccountID, stats.Throttled())
	}
	switch {
	case status == "ok" || status == "partial":
		// A success heals a degraded account only when no other job kind is still failing.
		_, _ = tx.Exec(bg, `UPDATE cloud_accounts SET last_success_at=now(),
			status = CASE WHEN status IN ('degraded','error') AND NOT EXISTS (
				SELECT 1 FROM collection_jobs WHERE cloud_account_id=$1 AND consecutive_failures >= 3) THEN 'active' ELSE status END,
			status_reason = CASE WHEN status IN ('degraded','error') AND NOT EXISTS (
				SELECT 1 FROM collection_jobs WHERE cloud_account_id=$1 AND consecutive_failures >= 3) THEN NULL ELSE status_reason END
			WHERE id=$1 AND status <> 'disabled'`, j.AccountID)
	case accountStatus != "":
		_, _ = tx.Exec(bg, `UPDATE cloud_accounts SET status=$2, status_reason=$3, updated_at=now() WHERE id=$1 AND status <> 'disabled'`,
			j.AccountID, accountStatus, truncate(accountReason, 500))
	}
	if err := tx.Commit(bg); err != nil {
		s.log.Error("record job commit", "err", err)
	}
}

func (s *Scheduler) execute(ctx context.Context, j job) (RunResult, error) {
	acct, provider, err := s.LoadAccount(ctx, j.OrgID, j.AccountID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return RunResult{}, fmt.Errorf("account no longer exists")
		}
		return RunResult{}, err
	}
	ad, ok := s.adapters[provider]
	if acct.AuthMethod == "demo" {
		// Demo accounts only ever use the synthetic adapter, never a real cloud API.
		ad, ok = demo.New(provider), true
	}
	if !ok {
		return RunResult{}, fmt.Errorf("%w: no adapter for provider %s", providers.ErrNotSupported, provider)
	}
	switch j.Kind {
	case "discovery":
		return s.runDiscovery(ctx, ad, acct)
	case "metrics":
		return s.runMetrics(ctx, ad, acct)
	case "health":
		return s.runHealth(ctx, ad, acct)
	case "heartbeat":
		return s.runHeartbeat(ctx, ad, acct)
	case "events":
		since := s.now().Add(-time.Hour)
		if j.LastSuccess != nil && j.LastSuccess.After(since) {
			since = j.LastSuccess.Add(-10 * time.Minute)
		}
		return s.runEvents(ctx, ad, acct, since)
	}
	return RunResult{}, fmt.Errorf("unknown job kind %q", j.Kind)
}

func jitter(d time.Duration) time.Duration {
	f := 0.9 + rand.Float64()*0.2
	return time.Duration(float64(d) * f)
}

func backoff(base time.Duration, failures int) time.Duration {
	d := time.Duration(float64(base) * math.Pow(2, float64(failures-1)))
	if d > time.Hour || d <= 0 {
		d = time.Hour
	}
	return jitter(d)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
