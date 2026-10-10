package integration

import (
	"context"
	"io"
	"log/slog"
	"testing"

	"github.com/harsundeepwathan/az400/go/internal/agent"
	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// TestRealAgentEnrollsAndReports runs the actual agent code on this host against the
// ingest API and checks that real memory and per-volume disk data is stored.
func TestRealAgentEnrollsAndReports(t *testing.T) {
	h := setup(t)
	ctx := context.Background()
	dir := t.TempDir()
	cfg := &agent.Config{ServerURL: h.srv.URL, AllowInsecureHTTP: true, DisableCloudProbe: true}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	st, err := agent.Enroll(ctx, dir, cfg, "swe_test_token")
	if err != nil {
		t.Fatal(err)
	}
	c := agent.NewCollector(nil)
	c.Collect(ctx)
	samples, _ := c.Collect(ctx)
	host := agent.HostInfo(ctx)
	client, _ := agent.NewClient(cfg, func() string { return st.AgentID + "." + st.AgentSecret })
	var ack telemetry.BatchAck
	b := telemetry.Batch{Version: "1", BatchID: "0b8f0b1e-8a7c-4e3c-9d55-7d1b2c3a4f50", Seq: 1, SentAt: samples[0].TS,
		Host: &host, Metrics: samples, Agent: telemetry.AgentHealth{Version: agent.Version}}
	if err := client.Do(ctx, "POST", "/v1/agent/telemetry", b, &ack); err != nil {
		t.Fatal(err)
	}
	var mem float64
	var vols int
	must(t, h.pool.QueryRow(ctx, `SELECT value FROM metric_latest WHERE resource_id=$1 AND metric='memory.utilization'`, st.ResourceID).Scan(&mem))
	must(t, h.pool.QueryRow(ctx, `SELECT count(*) FROM metric_latest WHERE resource_id=$1 AND metric='disk.utilization'`, st.ResourceID).Scan(&vols))
	if mem <= 0 || mem > 100 || vols == 0 {
		t.Fatalf("real host data not stored: mem=%v volumes=%d", mem, vols)
	}
	t.Logf("host %s: memory %.1f%%, %d volume(s)", host.Hostname, mem, vols)
	_ = slog.New(slog.NewTextHandler(io.Discard, nil))
}
