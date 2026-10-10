// Package integration exercises the agent → ingest → evaluator → incident workflow
// against a real PostgreSQL database (acceptance scenarios 4–10).
package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/evaluator"
	"github.com/harsundeepwathan/az400/go/internal/ingest"
	"github.com/harsundeepwathan/az400/go/internal/testdb"
	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

type harness struct {
	t     *testing.T
	pool  *pgxpool.Pool
	srv   *httptest.Server
	eval  *evaluator.Evaluator
	orgID string
	auth  string
	seq   int64
	now   time.Time
	// dataClock is the timestamp of the newest sample sent so far.
	dataClock time.Time
	resID     string
	ctx       context.Context
	logger    *slog.Logger
}

func setup(t *testing.T) *harness {
	pool := testdb.New(t)
	ctx := context.Background()
	h := &harness{t: t, pool: pool, ctx: ctx, logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	must(t, pool.QueryRow(ctx, `INSERT INTO organizations(name, slug) VALUES ('Test Org','test-org') RETURNING id`).Scan(&h.orgID))
	exec(t, pool, `SELECT skywatch_init_org($1)`, h.orgID)
	exec(t, pool, `INSERT INTO agent_enrollment_tokens(org_id, token_hash, token_prefix, expires_at, max_uses)
		VALUES ($1,$2,'swe_test',now()+interval '1 hour',1)`, h.orgID, ingest.HashToken("swe_test_token"))
	exec(t, pool, `INSERT INTO platform_instances(instance_id, roles, version, hostname, started_at, last_heartbeat)
		VALUES ('test','{ingest}','test','test',now(),now()+interval '2 hours')`)
	h.srv = httptest.NewServer(ingest.New(pool, h.logger).Handler())
	t.Cleanup(h.srv.Close)
	h.eval = evaluator.New(pool, evaluator.Config{}, h.logger)
	h.dataClock = time.Now().UTC().Truncate(time.Minute).Add(-60 * time.Minute)
	h.now = time.Now().UTC()
	h.eval.SetClock(func() time.Time { return h.now })
	return h
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func exec(t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func (h *harness) post(path string, body any, auth string) (*http.Response, []byte) {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.srv.URL+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp, out
}

func (h *harness) enroll() {
	resp, body := h.post("/v1/agent/enroll", telemetry.EnrollRequest{
		EnrollmentToken: "swe_test_token", AgentVersion: "1.0.0",
		Host: telemetry.HostInfo{Hostname: "app-01", MachineID: "abc123", OSType: "linux", OSName: "Ubuntu", OSVersion: "24.04", Arch: "amd64"},
	}, "")
	if resp.StatusCode != http.StatusCreated {
		h.t.Fatalf("enroll: %d %s", resp.StatusCode, body)
	}
	var er telemetry.EnrollResponse
	must(h.t, json.Unmarshal(body, &er))
	h.auth = er.AgentID + "." + er.AgentSecret
	h.resID = er.ResourceID
	if len(er.Config.WatchedServices) != 1 || er.Config.WatchedServices[0] != "sshd" {
		h.t.Errorf("default policy should watch sshd on linux: %+v", er.Config)
	}
}

func (h *harness) batch(disk float64, nginx string) telemetry.Batch {
	h.seq++
	// Each batch covers the next six minutes of data; the evaluator clock follows.
	h.dataClock = h.dataClock.Add(6 * time.Minute)
	ts := h.dataClock
	h.now = ts.Add(30 * time.Second)
	var metrics []telemetry.Sample
	for i := 0; i < 6; i++ { // 6 one-minute points, so "for 5 minutes" rules can be judged
		t := ts.Add(-time.Duration(5-i) * time.Minute)
		metrics = append(metrics,
			telemetry.Sample{Metric: "cpu.utilization", TS: t, Value: 20},
			telemetry.Sample{Metric: "memory.utilization", TS: t, Value: 40},
			telemetry.Sample{Metric: "disk.utilization", Series: "mount=/", TS: t, Value: 50},
			telemetry.Sample{Metric: "disk.utilization", Series: "mount=/data", TS: t, Value: disk},
		)
	}
	return telemetry.Batch{Version: "1", BatchID: uuid.NewString(), Seq: h.seq, SentAt: time.Now().UTC(),
		Agent:   telemetry.AgentHealth{Version: "1.0.0"},
		Metrics: metrics,
		Services: []telemetry.Service{
			{Platform: "systemd", Name: "nginx.service", State: nginx, SubState: map[string]string{"running": "running", "failed": "failed"}[nginx]},
			{Platform: "systemd", Name: "sshd", State: "running"},
		}}
}

func (h *harness) send(b telemetry.Batch) telemetry.BatchAck {
	resp, body := h.post("/v1/agent/telemetry", b, h.auth)
	if resp.StatusCode != http.StatusOK {
		h.t.Fatalf("telemetry: %d %s", resp.StatusCode, body)
	}
	var ack telemetry.BatchAck
	must(h.t, json.Unmarshal(body, &ack))
	return ack
}

func (h *harness) cycle() {
	h.t.Helper()
	if err := h.eval.Cycle(h.ctx); err != nil {
		h.t.Fatalf("evaluator cycle: %v", err)
	}
}

func (h *harness) state() (string, string, map[string]any) {
	var st, reason string
	var sig []byte
	must(h.t, h.pool.QueryRow(h.ctx, `SELECT operational_state, state_reason, signals FROM resources WHERE id=$1`, h.resID).Scan(&st, &reason, &sig))
	m := map[string]any{}
	_ = json.Unmarshal(sig, &m)
	return st, reason, m
}

type incident struct{ ID, Title, Status, Severity string }

func (h *harness) incidents() []incident {
	rows, err := h.pool.Query(h.ctx, `SELECT id, title, status, severity FROM incidents WHERE org_id=$1 ORDER BY number`, h.orgID)
	must(h.t, err)
	defer rows.Close()
	var out []incident
	for rows.Next() {
		var i incident
		must(h.t, rows.Scan(&i.ID, &i.Title, &i.Status, &i.Severity))
		out = append(out, i)
	}
	return out
}

func TestAgentToIncidentWorkflow(t *testing.T) {
	h := setup(t)

	// Scenario 4: enroll an agent.
	h.enroll()
	resp, _ := h.post("/v1/agent/enroll", telemetry.EnrollRequest{EnrollmentToken: "swe_test_token",
		Host: telemetry.HostInfo{Hostname: "x", OSType: "linux"}}, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("single-use token must not enroll twice: %d", resp.StatusCode)
	}

	// Scenario 5: memory and per-volume disk usage arrive; idempotent re-delivery.
	b := h.batch(50, "running")
	ack := h.send(b)
	if ack.Accepted == 0 || ack.Duplicate {
		t.Fatalf("first delivery: %+v", ack)
	}
	if again := h.send(b); !again.Duplicate {
		t.Fatalf("re-delivered batch must be acknowledged as duplicate: %+v", again)
	}
	var vols int
	must(t, h.pool.QueryRow(h.ctx, `SELECT count(*) FROM metric_latest WHERE resource_id=$1 AND metric='disk.utilization'`, h.resID).Scan(&vols))
	if vols != 2 {
		t.Fatalf("expected two volumes, got %d", vols)
	}
	h.cycle()
	if st, reason, _ := h.state(); st != "healthy" {
		t.Fatalf("expected healthy, got %s (%s)", st, reason)
	}

	// Operator marks nginx as required.
	exec(t, h.pool, `UPDATE service_checks SET expected_state='running', critical=true WHERE resource_id=$1 AND name='nginx.service'`, h.resID)

	// Scenario 8: disk threshold alert -> incident.
	h.send(h.batch(93, "running"))
	h.cycle()
	st, reason, _ := h.state()
	if st != "critical" {
		rows, _ := h.pool.Query(h.ctx, `SELECT r.name, a.series, a.state, coalesce(a.value,-1), a.summary FROM alert_instances a JOIN alert_rules r ON r.id=a.rule_id`)
		for rows.Next() {
			var n, se, stt, sum string
			var v float64
			_ = rows.Scan(&n, &se, &stt, &v, &sum)
			t.Logf("%s %s %s %v %s", n, se, stt, v, sum)
		}
		rows.Close()
		var mx time.Time
		_ = h.pool.QueryRow(h.ctx, `SELECT max(ts) FROM metric_samples`).Scan(&mx)
		t.Logf("max ts %v now %v", mx, h.now)
	}
	if st != "critical" || !strings.Contains(reason, "/data") {
		t.Fatalf("expected critical disk state, got %s (%s)", st, reason)
	}
	incs := h.incidents()
	if len(incs) != 1 || incs[0].Severity != "critical" || incs[0].Status != "open" {
		t.Fatalf("expected one open critical incident: %+v", incs)
	}

	// Scenario 9: acknowledge (as the API does).
	exec(t, h.pool, `UPDATE incidents SET status='acknowledged', acknowledged_at=now() WHERE id=$1`, incs[0].ID)

	// Scenario 6: deliberately stopped service is detected and joins the same incident.
	h.send(h.batch(93, "failed"))
	h.cycle()
	if st, reason, _ := h.state(); st != "critical" {
		t.Fatalf("expected critical, got %s (%s)", st, reason)
	}
	var svcFiring int
	must(t, h.pool.QueryRow(h.ctx, `SELECT count(*) FROM alert_instances a JOIN alert_rules r ON r.id=a.rule_id
		WHERE r.kind='service_state' AND a.state='firing' AND a.incident_id=$1`, incs[0].ID).Scan(&svcFiring))
	if svcFiring != 1 {
		t.Fatalf("service alert should fire and attach to the existing incident")
	}
	if n := len(h.incidents()); n != 1 {
		t.Fatalf("alerts on the same resource must be grouped, got %d incidents", n)
	}
	var events int
	must(t, h.pool.QueryRow(h.ctx, `SELECT count(*) FROM service_events WHERE resource_id=$1 AND to_state='failed'`, h.resID).Scan(&events))
	if events != 1 {
		t.Fatalf("service transition not recorded")
	}

	// Scenario 10: recovery resolves the incident automatically.
	h.send(h.batch(50, "running"))
	h.cycle()
	incs = h.incidents()
	if incs[0].Status != "resolved" {
		t.Fatalf("incident should auto-resolve after recovery: %+v", incs[0])
	}
	if st, reason, _ := h.state(); st != "healthy" {
		t.Fatalf("expected healthy after recovery, got %s (%s)", st, reason)
	}
	var timeline []string
	rows, _ := h.pool.Query(h.ctx, `SELECT kind FROM incident_events WHERE incident_id=$1 ORDER BY id`, incs[0].ID)
	for rows.Next() {
		var k string
		_ = rows.Scan(&k)
		timeline = append(timeline, k)
	}
	rows.Close()
	if timeline[0] != "opened" || timeline[len(timeline)-1] != "resolved" {
		t.Fatalf("timeline = %v", timeline)
	}

	// Scenario 7: heartbeat goes silent. Without independent evidence this is critical
	// with "host status unconfirmed", never a confirmed outage.
	h.now = time.Now().UTC().Add(10 * time.Minute)
	h.cycle()
	st, reason, sig := h.state()
	if st != "critical" || !strings.Contains(reason, "unconfirmed") || sig["host_confirmed_down"] != false {
		t.Fatalf("missing heartbeat must be critical/unconfirmed, got %s (%s) %v", st, reason, sig["host_confirmed_down"])
	}
	incs = h.incidents()
	if len(incs) != 2 || !strings.Contains(incs[1].Title, "Heartbeat missing") {
		t.Fatalf("expected a heartbeat incident: %+v", incs)
	}

	// A failing liveness check corroborates the outage -> Down.
	exec(t, h.pool, `INSERT INTO synthetic_checks(org_id, resource_id, name, kind, target, counts_for_liveness, last_run_at, last_ok, consecutive_failures, interval_seconds)
		VALUES ($1,$2,'ssh','tcp','10.0.0.4:22',true,$3,false,3,60)`, h.orgID, h.resID, h.now)
	h.cycle()
	if st, reason, sig := h.state(); st != "down" || sig["host_confirmed_down"] != true {
		t.Fatalf("expected confirmed down, got %s (%s)", st, reason)
	}
}

func TestAgentAuthAndRotation(t *testing.T) {
	h := setup(t)
	h.enroll()
	old := h.auth
	resp, body := h.post("/v1/agent/rotate", map[string]any{}, old)
	if resp.StatusCode != 200 {
		t.Fatalf("rotate: %d %s", resp.StatusCode, body)
	}
	var rr telemetry.RotateResponse
	must(t, json.Unmarshal(body, &rr))
	id := strings.SplitN(old, ".", 2)[0]
	h.auth = id + "." + rr.AgentSecret
	h.send(h.batch(10, "running"))
	h.auth = old
	h.send(h.batch(10, "running")) // previous secret valid during grace period
	exec(t, h.pool, `UPDATE agents SET prev_secret_expires_at = now() - interval '1 second' WHERE id=$1`, id)
	if resp, _ := h.post("/v1/agent/telemetry", h.batch(10, "running"), old); resp.StatusCode != 401 {
		t.Fatalf("expired previous secret must be rejected: %d", resp.StatusCode)
	}
	if resp, _ := h.post("/v1/agent/telemetry", h.batch(10, "running"), id+".wrong"); resp.StatusCode != 401 {
		t.Fatalf("bad secret must be rejected")
	}
	// Revoked agents are rejected.
	exec(t, h.pool, `UPDATE agents SET status='revoked' WHERE id=$1`, id)
	if resp, _ := h.post("/v1/agent/telemetry", h.batch(10, "running"), id+"."+rr.AgentSecret); resp.StatusCode != 401 {
		t.Fatalf("revoked agent must be rejected")
	}
}

func TestInvalidBatchRejected(t *testing.T) {
	h := setup(t)
	h.enroll()
	b := h.batch(10, "running")
	b.Metrics[0].Metric = "DROP TABLE"
	if resp, _ := h.post("/v1/agent/telemetry", b, h.auth); resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("invalid metric name must be rejected: %d", resp.StatusCode)
	}
	raw := map[string]any{"version": "1", "batch_id": uuid.NewString(), "unexpected": true}
	if resp, _ := h.post("/v1/agent/telemetry", raw, h.auth); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("unknown fields must be rejected: %d", resp.StatusCode)
	}
}
