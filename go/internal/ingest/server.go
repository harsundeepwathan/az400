// Package ingest implements the agent-facing HTTPS API (contract: pkg/telemetry v1).
//
// Security properties:
//   - Agents connect outbound only; this API never initiates connections to agents and
//     exposes no command channel (no remote execution by design).
//   - Enrollment tokens are single/limited-use, expiring, stored as SHA-256 hashes.
//   - Agent secrets are 256-bit random values, stored as SHA-256 hashes, compared in
//     constant time, rotatable with a short grace period for the previous secret.
//   - Request bodies are size-limited and schema-validated; per-agent and per-IP rate
//     limits bound abuse.
package ingest

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/time/rate"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/selfmon"
	"github.com/harsundeepwathan/az400/go/internal/tsdb"
	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// Server is the agent ingest API.
type Server struct {
	pool *pgxpool.Pool
	log  *slog.Logger
	now  func() time.Time
	// RotationGrace is how long a previous agent secret remains valid after rotation.
	RotationGrace time.Duration
	// TrustProxyHeaders enables X-Forwarded-For for client IP (only behind a trusted LB).
	TrustProxyHeaders bool

	limMu    sync.Mutex
	limiters map[string]*rate.Limiter
}

// New creates the server.
func New(pool *pgxpool.Pool, log *slog.Logger) *Server {
	return &Server{pool: pool, log: log, now: time.Now, RotationGrace: 15 * time.Minute, limiters: map[string]*rate.Limiter{}}
}

// Handler returns the HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/agent/enroll", s.handleEnroll)
	mux.HandleFunc("POST /v1/agent/telemetry", s.handleTelemetry)
	mux.HandleFunc("POST /v1/agent/rotate", s.handleRotate)
	mux.HandleFunc("GET /v1/agent/config", s.handleConfig)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := s.pool.Ping(ctx); err != nil {
			http.Error(w, "db unavailable", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte("ok"))
	})
	return securityHeaders(mux)
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		h.ServeHTTP(w, r)
	})
}

type apiError struct {
	Error string `json:"error"`
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, msg string) { writeJSON(w, code, apiError{Error: msg}) }

func (s *Server) allow(key string, r rate.Limit, burst int) bool {
	s.limMu.Lock()
	defer s.limMu.Unlock()
	l, ok := s.limiters[key]
	if !ok {
		if len(s.limiters) > 100_000 { // bound memory under abuse
			s.limiters = map[string]*rate.Limiter{}
		}
		l = rate.NewLimiter(r, burst)
		s.limiters[key] = l
	}
	return l.Allow()
}

func (s *Server) clientIP(r *http.Request) string {
	if s.TrustProxyHeaders {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			return strings.TrimSpace(strings.Split(xff, ",")[0])
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// HashToken returns the SHA-256 of a token string; shared with the TypeScript API.
func HashToken(tok string) []byte {
	h := sha256.Sum256([]byte(tok))
	return h[:]
}

func newSecret() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func decode(w http.ResponseWriter, r *http.Request, v any) error {
	body := http.MaxBytesReader(w, r.Body, telemetry.MaxBatchBytes)
	dec := json.NewDecoder(body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return errors.New("trailing data")
	}
	return nil
}

// --- enrollment -----------------------------------------------------------------------

func (s *Server) handleEnroll(w http.ResponseWriter, r *http.Request) {
	ip := s.clientIP(r)
	if !s.allow("enroll:"+ip, rate.Every(6*time.Second), 10) {
		fail(w, http.StatusTooManyRequests, "rate limited")
		return
	}
	var req telemetry.EnrollRequest
	if err := decode(w, r, &req); err != nil {
		fail(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if req.EnrollmentToken == "" || req.Host.Hostname == "" || (req.Host.OSType != "linux" && req.Host.OSType != "windows") {
		fail(w, http.StatusBadRequest, "enrollment_token, host.hostname and host.os_type (linux|windows) are required")
		return
	}
	resp, err := s.enroll(r.Context(), req, ip)
	if err != nil {
		if errors.Is(err, errBadToken) {
			fail(w, http.StatusUnauthorized, "enrollment token invalid, expired, revoked or exhausted")
			return
		}
		s.log.Error("enroll", "err", err)
		fail(w, http.StatusInternalServerError, "enrollment failed")
		return
	}
	writeJSON(w, http.StatusCreated, resp)
}

var errBadToken = errors.New("bad enrollment token")

func (s *Server) enroll(ctx context.Context, req telemetry.EnrollRequest, ip string) (*telemetry.EnrollResponse, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var tokenID, orgID string
	err = tx.QueryRow(ctx, `UPDATE agent_enrollment_tokens SET uses = uses + 1
		WHERE token_hash=$1 AND revoked_at IS NULL AND expires_at > now() AND uses < max_uses
		RETURNING id, org_id`, HashToken(req.EnrollmentToken)).Scan(&tokenID, &orgID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errBadToken
	}
	if err != nil {
		return nil, err
	}

	provider, providerID, rtype := linkTarget(req)
	hostJSON, _ := json.Marshal(req.Host)
	cloudJSON, _ := json.Marshal(req.Cloud)
	var resourceID string
	err = tx.QueryRow(ctx, `
		INSERT INTO resources(org_id, provider, provider_resource_id, name, resource_type, region, os_type, os_name, power_state, config)
		VALUES ($1,$2,$3,$4,$5,nullif($6,''),$7,$8,$9,'{}')
		ON CONFLICT (org_id, provider, provider_resource_id) DO UPDATE
		SET os_type = EXCLUDED.os_type, os_name = coalesce(resources.os_name, EXCLUDED.os_name), deleted_at = NULL
		RETURNING id`,
		orgID, provider, providerID, req.Host.Hostname, rtype, req.Cloud.Region, req.Host.OSType,
		strings.TrimSpace(req.Host.OSName+" "+req.Host.OSVersion), powerFor(provider)).Scan(&resourceID)
	if err != nil {
		return nil, err
	}
	// One active agent per resource: a re-installed agent supersedes the old identity.
	if _, err := tx.Exec(ctx, `UPDATE agents SET status='revoked' WHERE resource_id=$1 AND status='active'`, resourceID); err != nil {
		return nil, err
	}
	secret, err := newSecret()
	if err != nil {
		return nil, err
	}
	var agentID string
	err = tx.QueryRow(ctx, `INSERT INTO agents(org_id, resource_id, enrollment_token_id, hostname, os_type, os_name, os_version,
			kernel_version, arch, agent_version, secret_hash, cloud_metadata, machine_id, host_info, last_ip)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,nullif($13,''),$14,$15) RETURNING id`,
		orgID, resourceID, tokenID, req.Host.Hostname, req.Host.OSType, req.Host.OSName, req.Host.OSVersion,
		req.Host.KernelVersion, req.Host.Arch, req.AgentVersion, HashToken(secret), cloudJSON, req.Host.MachineID, hostJSON, ip).Scan(&agentID)
	if err != nil {
		return nil, err
	}
	details, _ := json.Marshal(map[string]any{"hostname": req.Host.Hostname, "resource_id": resourceID, "agent_version": req.AgentVersion})
	if _, err := tx.Exec(ctx, `INSERT INTO audit_logs(org_id, actor_type, actor_id, actor_label, action, target_type, target_id, details, ip)
		VALUES ($1,'agent',$2,$3,'agent.enrolled','agent',$2,$4,$5)`, orgID, agentID, req.Host.Hostname, details, ip); err != nil {
		return nil, err
	}
	cfg, err := agentConfig(ctx, tx, orgID, resourceID, req.Host.OSType)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &telemetry.EnrollResponse{AgentID: agentID, AgentSecret: secret, ResourceID: resourceID, Config: cfg}, nil
}

// linkTarget decides which inventory record an agent attaches to. Cloud instance
// metadata links the agent to the discovered VM (or pre-creates the record that
// discovery will later fill in); otherwise the host's machine ID gives a stable
// on-premises identity that survives agent re-installation.
func linkTarget(req telemetry.EnrollRequest) (provider, providerID, rtype string) {
	switch req.Cloud.Provider {
	case "azure":
		if req.Cloud.ResourceID != "" {
			return "azure", strings.ToLower(req.Cloud.ResourceID), "vm"
		}
	case "digitalocean":
		if req.Cloud.InstanceID != "" {
			return "digitalocean", req.Cloud.InstanceID, "vm"
		}
	case "alibaba":
		if req.Cloud.InstanceID != "" {
			return "alibaba", req.Cloud.InstanceID, "vm"
		}
	}
	id := req.Host.MachineID
	if id == "" {
		id = strings.ToLower(req.Host.Hostname)
	}
	return "onprem", "host:" + id, "server"
}

func powerFor(provider string) string {
	if provider == "onprem" {
		return "not_applicable"
	}
	return "unknown"
}

type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// agentConfig resolves server-driven agent configuration from the org's default
// monitoring policy and the services operators marked as required for this resource.
func agentConfig(ctx context.Context, q querier, orgID, resourceID, osType string) (telemetry.AgentConfig, error) {
	cfg := telemetry.AgentConfig{HeartbeatIntervalSeconds: 60, MetricsIntervalSeconds: 60, ServiceIntervalSeconds: 60, DiscoverServices: true}
	var watched []byte
	err := q.QueryRow(ctx, `SELECT heartbeat_interval_s, metrics_interval_s, watched_services, discover_services
		FROM monitoring_policies WHERE org_id=$1 AND is_default`, orgID).
		Scan(&cfg.HeartbeatIntervalSeconds, &cfg.MetricsIntervalSeconds, &watched, &cfg.DiscoverServices)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return cfg, err
	}
	cfg.ServiceIntervalSeconds = cfg.MetricsIntervalSeconds
	set := map[string]bool{}
	var byOS map[string][]string
	_ = json.Unmarshal(watched, &byOS)
	for _, n := range byOS[osType] {
		set[n] = true
	}
	rows, err := q.Query(ctx, `SELECT name FROM service_checks WHERE resource_id=$1 AND expected_state <> 'any'`, resourceID)
	if err != nil {
		return cfg, err
	}
	defer rows.Close()
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return cfg, err
		}
		set[n] = true
	}
	for n := range set {
		cfg.WatchedServices = append(cfg.WatchedServices, n)
	}
	return cfg, rows.Err()
}

// --- authentication -------------------------------------------------------------------

type agentIdentity struct {
	ID, OrgID, ResourceID, OSType string
}

func (s *Server) authenticate(r *http.Request) (*agentIdentity, error) {
	h := r.Header.Get("Authorization")
	tok, ok := strings.CutPrefix(h, "Bearer ")
	if !ok {
		return nil, errors.New("missing bearer credential")
	}
	id, secret, ok := strings.Cut(tok, ".")
	if !ok || len(id) != 36 || secret == "" {
		return nil, errors.New("malformed credential")
	}
	var (
		a          agentIdentity
		cur, prev  []byte
		prevExpiry *time.Time
		status     string
		resourceID *string
	)
	err := s.pool.QueryRow(r.Context(), `SELECT id, org_id, resource_id, os_type, secret_hash, prev_secret_hash, prev_secret_expires_at, status
		FROM agents WHERE id=$1`, id).Scan(&a.ID, &a.OrgID, &resourceID, &a.OSType, &cur, &prev, &prevExpiry, &status)
	if err != nil {
		return nil, errors.New("unknown agent")
	}
	got := HashToken(secret)
	match := subtle.ConstantTimeCompare(got, cur) == 1
	if !match && prev != nil && prevExpiry != nil && s.now().Before(*prevExpiry) {
		match = subtle.ConstantTimeCompare(got, prev) == 1
	}
	if !match {
		return nil, errors.New("bad secret")
	}
	if status != "active" {
		return nil, errors.New("agent revoked")
	}
	if resourceID != nil {
		a.ResourceID = *resourceID
	}
	return &a, nil
}

func (s *Server) authed(w http.ResponseWriter, r *http.Request) *agentIdentity {
	a, err := s.authenticate(r)
	if err != nil {
		selfmon.IngestBatches.WithLabelValues("unauthorized").Inc()
		fail(w, http.StatusUnauthorized, "unauthorized")
		return nil
	}
	if !s.allow("agent:"+a.ID, rate.Every(time.Second), 30) {
		selfmon.IngestBatches.WithLabelValues("rate_limited").Inc()
		w.Header().Set("Retry-After", "5")
		fail(w, http.StatusTooManyRequests, "rate limited")
		return nil
	}
	return a
}

func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	a := s.authed(w, r)
	if a == nil {
		return
	}
	cfg, err := agentConfig(r.Context(), s.pool, a.OrgID, a.ResourceID, a.OSType)
	if err != nil {
		fail(w, http.StatusInternalServerError, "config unavailable")
		return
	}
	writeJSON(w, http.StatusOK, cfg)
}

func (s *Server) handleRotate(w http.ResponseWriter, r *http.Request) {
	a := s.authed(w, r)
	if a == nil {
		return
	}
	secret, err := newSecret()
	if err != nil {
		fail(w, http.StatusInternalServerError, "rotation failed")
		return
	}
	until := s.now().Add(s.RotationGrace)
	_, err = s.pool.Exec(r.Context(), `UPDATE agents SET prev_secret_hash = secret_hash, prev_secret_expires_at=$2,
		secret_hash=$3, secret_rotated_at=now() WHERE id=$1`, a.ID, until, HashToken(secret))
	if err != nil {
		fail(w, http.StatusInternalServerError, "rotation failed")
		return
	}
	_, _ = s.pool.Exec(r.Context(), `INSERT INTO audit_logs(org_id, actor_type, actor_id, action, target_type, target_id, ip)
		VALUES ($1,'agent',$2,'agent.secret_rotated','agent',$2,$3)`, a.OrgID, a.ID, s.clientIP(r))
	writeJSON(w, http.StatusOK, telemetry.RotateResponse{AgentSecret: secret, PreviousValidTil: until})
}

// --- telemetry ------------------------------------------------------------------------

func (s *Server) handleTelemetry(w http.ResponseWriter, r *http.Request) {
	a := s.authed(w, r)
	if a == nil {
		return
	}
	var b telemetry.Batch
	if err := decode(w, r, &b); err != nil {
		selfmon.IngestBatches.WithLabelValues("invalid").Inc()
		fail(w, http.StatusBadRequest, "invalid batch: "+err.Error())
		return
	}
	if err := b.Validate(); err != nil {
		selfmon.IngestBatches.WithLabelValues("invalid").Inc()
		fail(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	start := s.now()
	ack, err := s.ingest(r.Context(), a, &b, s.clientIP(r))
	selfmon.IngestLatency.Observe(time.Since(start).Seconds())
	if err != nil {
		selfmon.IngestBatches.WithLabelValues("error").Inc()
		s.log.Error("ingest batch", "agent", a.ID, "err", err)
		fail(w, http.StatusServiceUnavailable, "temporarily unable to persist batch")
		return
	}
	if ack.Duplicate {
		selfmon.IngestBatches.WithLabelValues("duplicate").Inc()
	} else {
		selfmon.IngestBatches.WithLabelValues("accepted").Inc()
		selfmon.IngestSamples.Add(float64(ack.Accepted))
	}
	writeJSON(w, http.StatusOK, ack)
}

func (s *Server) ingest(ctx context.Context, a *agentIdentity, b *telemetry.Batch, ip string) (*telemetry.BatchAck, error) {
	now := s.now().UTC()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	tag, err := tx.Exec(ctx, `INSERT INTO agent_batches(batch_id, org_id, agent_id, seq) VALUES ($1,$2,$3,$4)
		ON CONFLICT (batch_id) DO NOTHING`, b.BatchID, a.OrgID, a.ID, b.Seq)
	if err != nil {
		return nil, err
	}
	ack := &telemetry.BatchAck{}
	if tag.RowsAffected() == 0 {
		ack.Duplicate = true
	} else {
		if err := s.apply(ctx, tx, a, b, now, ip, ack); err != nil {
			return nil, err
		}
	}
	if ack.Config, err = agentConfig(ctx, tx, a.OrgID, a.ResourceID, a.OSType); err != nil {
		return nil, err
	}
	return ack, tx.Commit(ctx)
}

func (s *Server) apply(ctx context.Context, tx pgx.Tx, a *agentIdentity, b *telemetry.Batch, now time.Time, ip string, ack *telemetry.BatchAck) error {
	latency := now.Sub(b.SentAt).Milliseconds()
	if latency < 0 {
		latency = 0 // agent clock ahead of ours; never report negative latency
	}
	if _, err := tx.Exec(ctx, `INSERT INTO heartbeats(org_id, agent_id, resource_id, sent_at, received_at, latency_ms, seq)
		VALUES ($1,$2,$3,$4,$5,$6,$7)`, a.OrgID, a.ID, nullable(a.ResourceID), b.SentAt.UTC(), now, latency, b.Seq); err != nil {
		return err
	}
	partial, _ := json.Marshal(b.Partial)
	if partial == nil || string(partial) == "null" {
		partial = []byte("[]")
	}
	if _, err := tx.Exec(ctx, `UPDATE agents SET last_heartbeat_at = $2, last_heartbeat_latency_ms = $3,
			last_seq = GREATEST(last_seq, $4), agent_version = $5, last_queue_depth = $6, last_dropped_batches = $7,
			collector_errors = $8, last_ip = $9 WHERE id = $1`,
		a.ID, now, latency, b.Seq, b.Agent.Version, b.Agent.QueueDepth, b.Agent.DroppedBatches, partial, ip); err != nil {
		return err
	}
	if b.Host != nil {
		host, _ := json.Marshal(b.Host)
		var boot *time.Time
		if !b.Host.BootTime.IsZero() {
			bt := b.Host.BootTime.UTC()
			boot = &bt
		}
		if _, err := tx.Exec(ctx, `UPDATE agents SET host_info=$2, hostname=$3, os_name=$4, os_version=$5, kernel_version=$6,
				last_boot_at=$7 WHERE id=$1`, a.ID, host, b.Host.Hostname, b.Host.OSName, b.Host.OSVersion, b.Host.KernelVersion, boot); err != nil {
			return err
		}
	}
	if a.ResourceID == "" {
		return nil
	}
	samples := make([]model.Sample, 0, len(b.Metrics)+3)
	for _, m := range b.Metrics {
		samples = append(samples, model.Sample{Metric: m.Metric, Series: m.Series, TS: m.TS, Value: m.Value})
	}
	samples = append(samples,
		model.Sample{Metric: "agent.queue_depth", TS: b.SentAt, Value: float64(b.Agent.QueueDepth)},
		model.Sample{Metric: "agent.cpu_percent", TS: b.SentAt, Value: b.Agent.CPUPercent},
		model.Sample{Metric: "agent.rss_bytes", TS: b.SentAt, Value: float64(b.Agent.RSSBytes)})
	n, err := tsdb.WriteSamples(ctx, tx, a.OrgID, a.ResourceID, "agent", samples, now)
	if err != nil {
		return fmt.Errorf("write samples: %w", err)
	}
	ack.Accepted = n
	if _, err := tx.Exec(ctx, `UPDATE resources SET last_telemetry_at = GREATEST(coalesce(last_telemetry_at,'epoch'), $2) WHERE id=$1`,
		a.ResourceID, now); err != nil {
		return err
	}
	if err := s.applyServices(ctx, tx, a, b, now); err != nil {
		return fmt.Errorf("services: %w", err)
	}
	for _, e := range b.Events {
		extID := e.ID
		if extID == "" {
			extID = fmt.Sprintf("%s:%d:%s", a.ID, e.At.UnixNano(), e.Kind)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO infra_events(org_id, resource_id, source, kind, severity, message, at, external_id)
			VALUES ($1,$2,'agent',$3,$4,$5,$6,$7) ON CONFLICT (org_id, source, external_id) DO NOTHING`,
			a.OrgID, a.ResourceID, e.Kind, normSeverity(e.Severity), e.Message, e.At, a.ID+":"+extID); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) applyServices(ctx context.Context, tx pgx.Tx, a *agentIdentity, b *telemetry.Batch, now time.Time) error {
	for _, svc := range b.Services {
		var (
			id       string
			prev     *string
			inserted bool
		)
		err := tx.QueryRow(ctx, `
			WITH prev AS (SELECT id, current_state FROM service_checks WHERE resource_id=$2 AND platform=$3 AND name=$4)
			INSERT INTO service_checks(org_id, resource_id, agent_id, platform, name, display_name, startup_type, current_state,
				sub_state, pid, restart_count, last_change_at, last_reported_at, discovered)
			VALUES ($1,$2,$5,$3,$4,$6,$7,$8,$9,$10,$11,$12,$12,true)
			ON CONFLICT (resource_id, platform, name) DO UPDATE SET
				agent_id = EXCLUDED.agent_id, display_name = EXCLUDED.display_name, startup_type = EXCLUDED.startup_type,
				current_state = EXCLUDED.current_state, sub_state = EXCLUDED.sub_state, pid = EXCLUDED.pid,
				restart_count = EXCLUDED.restart_count, last_reported_at = EXCLUDED.last_reported_at,
				last_change_at = CASE WHEN service_checks.current_state IS DISTINCT FROM EXCLUDED.current_state
					THEN EXCLUDED.last_reported_at ELSE service_checks.last_change_at END
			RETURNING id, (SELECT current_state FROM prev), (xmax = 0)`,
			a.OrgID, a.ResourceID, svc.Platform, svc.Name, a.ID, nullable(svc.DisplayName), nullable(svc.StartupType),
			svc.State, nullable(svc.SubState), nullableInt(svc.PID), svc.Restarts, now).Scan(&id, &prev, &inserted)
		if err != nil {
			return err
		}
		if !inserted && prev != nil && *prev != svc.State {
			details, _ := json.Marshal(map[string]any{"sub_state": svc.SubState, "pid": svc.PID, "restarts": svc.Restarts})
			if _, err := tx.Exec(ctx, `INSERT INTO service_events(org_id, service_id, resource_id, from_state, to_state, at, details)
				VALUES ($1,$2,$3,$4,$5,$6,$7)`, a.OrgID, id, a.ResourceID, *prev, svc.State, now, details); err != nil {
				return err
			}
		}
	}
	return nil
}

func normSeverity(s string) string {
	switch s {
	case "warning", "error", "critical":
		return s
	}
	return "info"
}

func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func nullableInt(i int) *int {
	if i == 0 {
		return nil
	}
	return &i
}
