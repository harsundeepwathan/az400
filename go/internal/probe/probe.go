// Package probe executes synthetic checks (HTTP/HTTPS, TCP, DNS, TLS expiry, ICMP).
//
// A probe worker runs at a named location. The shared public probe refuses private,
// loopback, link-local and metadata destinations (netguard); endpoints inside private
// networks are checked by a private probe deployed in that network, which is the only
// mode allowed to reach RFC 1918 addresses.
package probe

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/netguard"
	"github.com/harsundeepwathan/az400/go/internal/selfmon"
	"github.com/harsundeepwathan/az400/go/internal/tsdb"
)

// Check is a synthetic check definition.
type Check struct {
	ID       string
	OrgID    string
	Name     string
	Kind     string
	Target   string
	Config   Config
	Resource string
}

// Config holds kind-specific options.
type Config struct {
	Method          string   `json:"method,omitempty"`
	ExpectedStatus  []int    `json:"expected_status,omitempty"`
	BodyContains    string   `json:"body_contains,omitempty"`
	TimeoutSeconds  int      `json:"timeout_seconds,omitempty"`
	FollowRedirects *bool    `json:"follow_redirects,omitempty"`
	Port            int      `json:"port,omitempty"`
	RecordType      string   `json:"record_type,omitempty"` // A | AAAA | CNAME | MX | TXT
	ExpectedValues  []string `json:"expected_values,omitempty"`
	WarnDays        int      `json:"warn_days,omitempty"`
	SkipTLSVerify   bool     `json:"skip_tls_verify,omitempty"`
}

// Result of one execution.
type Result struct {
	OK         bool
	LatencyMs  int
	StatusCode int
	Error      string
	Details    map[string]any
	DaysToExp  *float64
}

// Runner executes checks with a network policy.
type Runner struct {
	Policy   netguard.Policy
	Resolver *net.Resolver
	// Pinger performs ICMP echo; nil means ICMP is unavailable at this probe.
	Pinger func(ctx context.Context, addr string) (time.Duration, error)
}

func (c Config) timeout() time.Duration {
	if c.TimeoutSeconds > 0 && c.TimeoutSeconds <= 60 {
		return time.Duration(c.TimeoutSeconds) * time.Second
	}
	return 10 * time.Second
}

// Run executes a check.
func (r *Runner) Run(ctx context.Context, c Check) Result {
	if r.Resolver == nil {
		r.Resolver = net.DefaultResolver
	}
	start := time.Now()
	var res Result
	switch c.Kind {
	case "http":
		res = r.http(ctx, c)
	case "tcp":
		res = r.tcp(ctx, c)
	case "dns":
		res = r.dns(ctx, c)
	case "tls":
		res = r.tlsExpiry(ctx, c)
	case "icmp":
		res = r.icmp(ctx, c)
	default:
		res = Result{Error: "unsupported check kind " + c.Kind}
	}
	if res.LatencyMs == 0 {
		res.LatencyMs = int(time.Since(start).Milliseconds())
	}
	if strings.Contains(res.Error, netguard.ErrBlocked.Error()) {
		res.Error = "Destination blocked by probe network policy (private, loopback or metadata address). Use a private probe for internal endpoints."
	}
	return res
}

func (r *Runner) http(ctx context.Context, c Check) Result {
	u, err := url.Parse(c.Target)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return Result{Error: "target must be an http(s) URL"}
	}
	follow := c.Config.FollowRedirects == nil || *c.Config.FollowRedirects
	client := r.Policy.HTTPClient(c.Config.timeout(), follow)
	if c.Config.SkipTLSVerify {
		client.Transport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // explicit per-check opt-in
	}
	method := strings.ToUpper(c.Config.Method)
	if method != "HEAD" {
		method = "GET"
	}
	req, err := http.NewRequestWithContext(ctx, method, c.Target, nil)
	if err != nil {
		return Result{Error: err.Error()}
	}
	req.Header.Set("User-Agent", "Skywatch-Synthetic/1")
	start := time.Now()
	resp, err := client.Do(req)
	lat := int(time.Since(start).Milliseconds())
	if err != nil {
		return Result{LatencyMs: lat, Error: classifyNetErr(err)}
	}
	defer resp.Body.Close()
	res := Result{LatencyMs: lat, StatusCode: resp.StatusCode, Details: map[string]any{"final_url": resp.Request.URL.String()}}
	if resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
		days := time.Until(resp.TLS.PeerCertificates[0].NotAfter).Hours() / 24
		res.DaysToExp = &days
	}
	expected := c.Config.ExpectedStatus
	if len(expected) == 0 {
		res.OK = resp.StatusCode >= 200 && resp.StatusCode < 400
	} else {
		for _, s := range expected {
			if s == resp.StatusCode {
				res.OK = true
			}
		}
	}
	if !res.OK {
		res.Error = fmt.Sprintf("unexpected HTTP status %d", resp.StatusCode)
		return res
	}
	if c.Config.BodyContains != "" {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		if !strings.Contains(string(body), c.Config.BodyContains) {
			res.OK = false
			res.Error = "response body does not contain the expected text"
		}
	}
	return res
}

func splitHostPort(target string, defPort int) (string, int, error) {
	host, portS, err := net.SplitHostPort(target)
	if err != nil {
		if defPort == 0 {
			return "", 0, errors.New("target must be host:port")
		}
		return target, defPort, nil
	}
	p, err := strconv.Atoi(portS)
	if err != nil || p <= 0 || p > 65535 {
		return "", 0, errors.New("invalid port")
	}
	return host, p, nil
}

func (r *Runner) tcp(ctx context.Context, c Check) Result {
	host, port, err := splitHostPort(c.Target, c.Config.Port)
	if err != nil {
		return Result{Error: err.Error()}
	}
	d := r.Policy.Dialer(c.Config.timeout())
	start := time.Now()
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	lat := int(time.Since(start).Milliseconds())
	if err != nil {
		return Result{LatencyMs: lat, Error: classifyNetErr(err)}
	}
	_ = conn.Close()
	return Result{OK: true, LatencyMs: lat}
}

func (r *Runner) dns(ctx context.Context, c Check) Result {
	ctx, cancel := context.WithTimeout(ctx, c.Config.timeout())
	defer cancel()
	name := strings.TrimSuffix(c.Target, ".")
	start := time.Now()
	var answers []string
	var err error
	switch strings.ToUpper(c.Config.RecordType) {
	case "", "A", "AAAA":
		var ips []net.IP
		ips, err = r.Resolver.LookupIP(ctx, map[string]string{"": "ip", "A": "ip4", "AAAA": "ip6"}[strings.ToUpper(c.Config.RecordType)], name)
		for _, ip := range ips {
			answers = append(answers, ip.String())
		}
	case "CNAME":
		var cn string
		cn, err = r.Resolver.LookupCNAME(ctx, name)
		answers = []string{strings.TrimSuffix(cn, ".")}
	case "MX":
		var mx []*net.MX
		mx, err = r.Resolver.LookupMX(ctx, name)
		for _, m := range mx {
			answers = append(answers, strings.TrimSuffix(m.Host, "."))
		}
	case "TXT":
		answers, err = r.Resolver.LookupTXT(ctx, name)
	default:
		return Result{Error: "unsupported record type"}
	}
	lat := int(time.Since(start).Milliseconds())
	if err != nil {
		return Result{LatencyMs: lat, Error: "DNS resolution failed: " + err.Error()}
	}
	res := Result{OK: len(answers) > 0, LatencyMs: lat, Details: map[string]any{"answers": answers}}
	if !res.OK {
		res.Error = "no records returned"
	}
	for _, want := range c.Config.ExpectedValues {
		found := false
		for _, a := range answers {
			if strings.EqualFold(a, want) {
				found = true
			}
		}
		if !found {
			res.OK = false
			res.Error = fmt.Sprintf("expected value %q not in answers", want)
		}
	}
	return res
}

func (r *Runner) tlsExpiry(ctx context.Context, c Check) Result {
	host, port, err := splitHostPort(c.Target, 443)
	if err != nil {
		return Result{Error: err.Error()}
	}
	d := r.Policy.Dialer(c.Config.timeout())
	start := time.Now()
	raw, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return Result{Error: classifyNetErr(err)}
	}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(c.Config.timeout()))
	conn := tls.Client(raw, &tls.Config{ServerName: host, InsecureSkipVerify: true}) //nolint:gosec // verified manually below to report details
	if err := conn.HandshakeContext(ctx); err != nil {
		return Result{LatencyMs: int(time.Since(start).Milliseconds()), Error: "TLS handshake failed: " + err.Error()}
	}
	lat := int(time.Since(start).Milliseconds())
	certs := conn.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return Result{LatencyMs: lat, Error: "no certificate presented"}
	}
	leaf := certs[0]
	days := time.Until(leaf.NotAfter).Hours() / 24
	res := Result{LatencyMs: lat, DaysToExp: &days, Details: map[string]any{
		"subject": leaf.Subject.CommonName, "issuer": leaf.Issuer.CommonName, "not_after": leaf.NotAfter, "dns_names": leaf.DNSNames}}
	inter := x509.NewCertPool()
	for _, ic := range certs[1:] {
		inter.AddCert(ic)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{DNSName: host, Intermediates: inter}); err != nil {
		res.Error = "certificate validation failed: " + err.Error()
		return res
	}
	warn := c.Config.WarnDays
	if warn <= 0 {
		warn = 14
	}
	if days < float64(warn) {
		res.Error = fmt.Sprintf("certificate expires in %.1f days (threshold %d)", days, warn)
		return res
	}
	res.OK = true
	return res
}

func (r *Runner) icmp(ctx context.Context, c Check) Result {
	if r.Pinger == nil {
		return Result{Error: "ICMP is not available at this probe location (requires raw socket privileges)"}
	}
	addr, err := r.Policy.Resolve(ctx, r.Resolver, c.Target, 0)
	if err != nil {
		return Result{Error: classifyNetErr(err)}
	}
	rtt, err := r.Pinger(ctx, addr.String())
	if err != nil {
		return Result{Error: "no echo reply: " + err.Error()}
	}
	return Result{OK: true, LatencyMs: int(rtt.Milliseconds())}
}

func classifyNetErr(err error) string {
	var dnsErr *net.DNSError
	switch {
	case errors.Is(err, netguard.ErrBlocked):
		return netguard.ErrBlocked.Error()
	case errors.As(err, &dnsErr):
		return "DNS resolution failed: " + dnsErr.Err
	case errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), "timeout"):
		return "timed out"
	case strings.Contains(err.Error(), "connection refused"):
		return "connection refused"
	}
	return err.Error()
}

// Worker claims due checks for its location and records results.
type Worker struct {
	Pool     *pgxpool.Pool
	Runner   *Runner
	Location string
	Scope    string // public | private
	OrgID    string // private probes serve one org
	Log      *slog.Logger
}

// Run loops until ctx is cancelled.
func (w *Worker) Run(ctx context.Context) error {
	t := time.NewTicker(2 * time.Second)
	defer t.Stop()
	for {
		if err := w.runDue(ctx); err != nil && ctx.Err() == nil {
			w.Log.Error("probe cycle", "err", err)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

func (w *Worker) runDue(ctx context.Context) error {
	rows, err := w.Pool.Query(ctx, `UPDATE synthetic_checks SET lease_until = now() + interval '90 seconds'
		WHERE id IN (SELECT id FROM synthetic_checks WHERE enabled AND next_run_at <= now()
			AND (lease_until IS NULL OR lease_until < now()) AND probe_scope=$1 AND $2 = ANY(locations)
			AND ($3 = '' OR org_id::text = $3)
			ORDER BY next_run_at FOR UPDATE SKIP LOCKED LIMIT 20)
		RETURNING id, org_id, name, kind, target, config, coalesce(resource_id::text,'')`, w.Scope, w.Location, w.OrgID)
	if err != nil {
		return err
	}
	var checks []Check
	for rows.Next() {
		var c Check
		var cfg []byte
		if err := rows.Scan(&c.ID, &c.OrgID, &c.Name, &c.Kind, &c.Target, &cfg, &c.Resource); err != nil {
			rows.Close()
			return err
		}
		_ = json.Unmarshal(cfg, &c.Config)
		checks = append(checks, c)
	}
	rows.Close()
	done := make(chan struct{}, len(checks))
	for _, c := range checks {
		go func(c Check) {
			defer func() { done <- struct{}{} }()
			cctx, cancel := context.WithTimeout(ctx, 70*time.Second)
			defer cancel()
			res := w.Runner.Run(cctx, c)
			if err := w.record(context.Background(), c, res); err != nil {
				w.Log.Error("record probe result", "check", c.ID, "err", err)
			}
		}(c)
	}
	for range checks {
		<-done
	}
	return nil
}

func (w *Worker) record(ctx context.Context, c Check, res Result) error {
	result := "ok"
	if !res.OK {
		result = "fail"
	}
	selfmon.ProbeRuns.WithLabelValues(c.Kind, result).Inc()
	now := time.Now().UTC()
	details, _ := json.Marshal(res.Details)
	var errText *string
	if res.Error != "" {
		errText = &res.Error
	}
	var status *int
	if res.StatusCode != 0 {
		status = &res.StatusCode
	}
	tx, err := w.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `INSERT INTO synthetic_results(org_id, check_id, location, at, ok, latency_ms, status_code, error, details)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, c.OrgID, c.ID, w.Location, now, res.OK, res.LatencyMs, status, errText, details); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE synthetic_checks SET last_run_at=$2, last_ok=$3, last_latency_ms=$4, last_error=$5, lease_until=NULL,
			consecutive_failures = CASE WHEN $3 THEN 0 ELSE consecutive_failures + 1 END,
			next_run_at = $2 + make_interval(secs => interval_seconds)
		WHERE id=$1`, c.ID, now, res.OK, res.LatencyMs, errText); err != nil {
		return err
	}
	if c.Resource != "" {
		samples := []model.Sample{
			{Metric: "synthetic.latency_ms", Series: "check=" + c.ID, TS: now, Value: float64(res.LatencyMs)},
			{Metric: "synthetic.success", Series: "check=" + c.ID, TS: now, Value: map[bool]float64{true: 1, false: 0}[res.OK]},
		}
		if res.DaysToExp != nil && !math.IsNaN(*res.DaysToExp) {
			samples = append(samples, model.Sample{Metric: "tls.days_to_expiry", Series: "check=" + c.ID, TS: now, Value: *res.DaysToExp})
		}
		if _, err := tsdb.WriteSamples(ctx, tx, c.OrgID, c.Resource, "synthetic:"+w.Location, samples, now); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
