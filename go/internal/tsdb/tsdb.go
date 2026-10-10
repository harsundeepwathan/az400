// Package tsdb writes and reads normalized telemetry in PostgreSQL.
package tsdb

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/harsundeepwathan/az400/go/internal/model"
)

// Execer is satisfied by *pgxpool.Pool, *pgx.Conn and pgx.Tx.
type Execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// Acceptance window for sample timestamps. Raw partitions exist from yesterday onward
// plus whatever retention keeps; very late data is dropped rather than failing the batch.
const (
	MaxLateness = 24 * time.Hour
	MaxFuture   = 10 * time.Minute
)

// WriteSamples inserts samples idempotently (duplicate resource/metric/series/ts/source
// rows are ignored) and refreshes metric_latest. Returns the number of samples accepted.
func WriteSamples(ctx context.Context, db Execer, orgID, resourceID, source string, samples []model.Sample, now time.Time) (int, error) {
	if len(samples) == 0 {
		return 0, nil
	}
	n := 0
	metrics := make([]string, 0, len(samples))
	series := make([]string, 0, len(samples))
	ts := make([]time.Time, 0, len(samples))
	vals := make([]float64, 0, len(samples))
	for _, s := range samples {
		if s.TS.Before(now.Add(-MaxLateness)) || s.TS.After(now.Add(MaxFuture)) {
			continue
		}
		metrics = append(metrics, s.Metric)
		series = append(series, s.Series)
		ts = append(ts, s.TS.UTC())
		vals = append(vals, s.Value)
		n++
	}
	if n == 0 {
		return 0, nil
	}
	_, err := db.Exec(ctx, `
		INSERT INTO metric_samples(org_id, resource_id, metric, series, ts, value, source)
		SELECT $1, $2, m, s, t, v, $3
		FROM unnest($4::text[], $5::text[], $6::timestamptz[], $7::float8[]) AS x(m, s, t, v)
		ON CONFLICT DO NOTHING`, orgID, resourceID, source, metrics, series, ts, vals)
	if err != nil {
		return 0, err
	}
	_, err = db.Exec(ctx, `
		INSERT INTO metric_latest(org_id, resource_id, metric, series, ts, value, source)
		SELECT DISTINCT ON (m, s) $1, $2, m, s, t, v, $3
		FROM unnest($4::text[], $5::text[], $6::timestamptz[], $7::float8[]) AS x(m, s, t, v)
		ORDER BY m, s, t DESC
		ON CONFLICT (resource_id, metric, series) DO UPDATE
		SET ts = EXCLUDED.ts, value = EXCLUDED.value, source = EXCLUDED.source
		WHERE metric_latest.ts <= EXCLUDED.ts`, orgID, resourceID, source, metrics, series, ts, vals)
	if err != nil {
		return 0, err
	}
	_, err = db.Exec(ctx, `UPDATE resources SET last_telemetry_at = GREATEST(coalesce(last_telemetry_at, 'epoch'), $2)
		WHERE id = $1`, resourceID, maxTS(ts))
	return n, err
}

func maxTS(ts []time.Time) time.Time {
	var m time.Time
	for _, t := range ts {
		if t.After(m) {
			m = t
		}
	}
	return m
}
