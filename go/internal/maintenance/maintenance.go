// Package maintenance implements data lifecycle: partition creation, hourly rollups and
// retention. Raw telemetry is never kept indefinitely.
package maintenance

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Retention policy. Defaults: raw 30 days, rollups 365 days.
type Retention struct {
	RawDays          int
	RollupDays       int
	SyntheticDays    int
	CollectorRunDays int
	AlertEventDays   int
}

// DefaultRetention is the initial data retention policy.
var DefaultRetention = Retention{RawDays: 30, RollupDays: 365, SyntheticDays: 30, CollectorRunDays: 14, AlertEventDays: 400}

const lockKey = 727274003

// Job runs maintenance tasks.
type Job struct {
	Pool      *pgxpool.Pool
	Retention Retention
	Log       *slog.Logger
}

// Run executes every interval until ctx is cancelled.
func (j *Job) Run(ctx context.Context, interval time.Duration) error {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		if err := j.Once(ctx); err != nil && ctx.Err() == nil {
			j.Log.Error("maintenance", "err", err)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

// Once runs all maintenance tasks under a cluster-wide advisory lock.
func (j *Job) Once(ctx context.Context) error {
	conn, err := j.Pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	var ok bool
	if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, lockKey).Scan(&ok); err != nil || !ok {
		return err
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, lockKey) //nolint:errcheck
	r := j.Retention
	steps := []struct {
		name string
		sql  string
		args []any
	}{
		{"partitions", `SELECT skywatch_ensure_daily_partitions('metric_samples', 7), skywatch_ensure_daily_partitions('heartbeats', 7)`, nil},
		// Recompute the last three complete hours plus the current hour (late data).
		{"rollups", `INSERT INTO metric_rollups_1h(org_id, resource_id, metric, series, source, bucket, avg, min, max, count)
			SELECT org_id, resource_id, metric, series, source, date_trunc('hour', ts), avg(value), min(value), max(value), count(*)
			FROM metric_samples WHERE ts >= date_trunc('hour', now()) - interval '3 hours'
			GROUP BY 1,2,3,4,5,6
			ON CONFLICT (resource_id, metric, series, source, bucket) DO UPDATE
			SET avg=EXCLUDED.avg, min=EXCLUDED.min, max=EXCLUDED.max, count=EXCLUDED.count`, nil},
		{"drop raw partitions", `SELECT skywatch_drop_old_partitions('metric_samples', $1)`, []any{r.RawDays}},
		{"drop heartbeat partitions", `SELECT skywatch_drop_old_partitions('heartbeats', $1)`, []any{r.RawDays}},
		{"rollup retention", `DELETE FROM metric_rollups_1h WHERE bucket < now() - make_interval(days => $1)`, []any{r.RollupDays}},
		{"synthetic retention", `DELETE FROM synthetic_results WHERE at < now() - make_interval(days => $1)`, []any{r.SyntheticDays}},
		{"collector run retention", `DELETE FROM collector_runs WHERE started_at < now() - make_interval(days => $1)`, []any{r.CollectorRunDays}},
		{"alert event retention", `DELETE FROM alert_events WHERE at < now() - make_interval(days => $1)`, []any{r.AlertEventDays}},
		{"batch dedup window", `DELETE FROM agent_batches WHERE received_at < now() - interval '48 hours'`, nil},
		{"expired sessions", `DELETE FROM sessions WHERE expires_at < now()`, nil},
		{"stale platform instances", `DELETE FROM platform_instances WHERE last_heartbeat < now() - interval '1 day'`, nil},
	}
	for _, s := range steps {
		if _, err := conn.Exec(ctx, s.sql, s.args...); err != nil {
			return fmt.Errorf("%s: %w", s.name, err)
		}
	}
	return nil
}
