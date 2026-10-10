package maintenance

import (
	"context"
	"io"
	"log/slog"
	"testing"

	"github.com/harsundeepwathan/az400/go/internal/testdb"
)

func TestOnceRollsUpAndAppliesRetention(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	var org, res string
	_ = pool.QueryRow(ctx, `INSERT INTO organizations(name, slug) VALUES ('m','maint-org') RETURNING id`).Scan(&org)
	_ = pool.QueryRow(ctx, `INSERT INTO resources(org_id, provider, provider_resource_id, name, resource_type) VALUES ($1,'onprem','x','x','server') RETURNING id`, org).Scan(&res)
	if _, err := pool.Exec(ctx, `INSERT INTO metric_samples(org_id, resource_id, metric, series, ts, value, source)
		SELECT $1, $2, 'cpu.utilization', '', date_trunc('hour', now()) - interval '1 hour' + (i || ' minutes')::interval, i, 'agent'
		FROM generate_series(0, 59) i`, org, res); err != nil {
		t.Fatal(err)
	}
	// An old partition outside retention.
	if _, err := pool.Exec(ctx, `CREATE TABLE metric_samples_p20000101 PARTITION OF metric_samples FOR VALUES FROM ('2000-01-01') TO ('2000-01-02')`); err != nil {
		t.Fatal(err)
	}
	j := &Job{Pool: pool, Retention: DefaultRetention, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := j.Once(ctx); err != nil {
		t.Fatal(err)
	}
	var avg, mx float64
	var n int
	if err := pool.QueryRow(ctx, `SELECT avg, max, count FROM metric_rollups_1h WHERE resource_id=$1`, res).Scan(&avg, &mx, &n); err != nil {
		t.Fatal(err)
	}
	if avg != 29.5 || mx != 59 || n != 60 {
		t.Fatalf("rollup avg=%v max=%v count=%d", avg, mx, n)
	}
	var exists bool
	_ = pool.QueryRow(ctx, `SELECT to_regclass('metric_samples_p20000101') IS NOT NULL`).Scan(&exists)
	if exists {
		t.Fatal("partition older than retention should be dropped")
	}
	if err := j.Once(ctx); err != nil { // idempotent
		t.Fatal(err)
	}
}
