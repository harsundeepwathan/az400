package probe

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/harsundeepwathan/az400/go/internal/netguard"
	"github.com/harsundeepwathan/az400/go/internal/testdb"
)

// TestWorkerRecordsResults runs due checks through the worker against a real database.
func TestWorkerRecordsResults(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer up.Close()
	var org, res string
	if err := pool.QueryRow(ctx, `INSERT INTO organizations(name, slug) VALUES ('p','probe-org') RETURNING id`).Scan(&org); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO resources(org_id, provider, provider_resource_id, name, resource_type) VALUES ($1,'onprem','x','x','server') RETURNING id`, org).Scan(&res); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO synthetic_checks(org_id, resource_id, name, kind, target, probe_scope) VALUES
		($1,$2,'up','http',$3,'private'), ($1,$2,'down','tcp','127.0.0.1:1','private')`, org, res, up.URL); err != nil {
		t.Fatal(err)
	}
	w := &Worker{Pool: pool, Runner: &Runner{Policy: netguard.Policy{AllowPrivate: true}}, Location: "default", Scope: "private", OrgID: org,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := w.runDue(ctx); err != nil {
		t.Fatal(err)
	}
	rows, _ := pool.Query(ctx, `SELECT name, last_ok, consecutive_failures, next_run_at > now() FROM synthetic_checks ORDER BY name`)
	defer rows.Close()
	got := map[string][3]any{}
	for rows.Next() {
		var n string
		var ok bool
		var f int
		var future bool
		_ = rows.Scan(&n, &ok, &f, &future)
		got[n] = [3]any{ok, f, future}
	}
	if got["up"] != [3]any{true, 0, true} || got["down"] != [3]any{false, 1, true} {
		t.Fatalf("results = %v", got)
	}
	var samples int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM metric_latest WHERE resource_id=$1 AND metric='synthetic.success'`, res).Scan(&samples)
	if samples != 2 {
		t.Fatalf("expected success samples for both checks, got %d", samples)
	}
}
