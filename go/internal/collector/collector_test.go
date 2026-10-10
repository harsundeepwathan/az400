package collector

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
	"github.com/harsundeepwathan/az400/go/internal/secrets"
	"github.com/harsundeepwathan/az400/go/internal/testdb"
)

type stubAdapter struct {
	resources []model.DiscoveredResource
	metricErr error
}

func (s *stubAdapter) Provider() model.Provider                 { return model.ProviderAzure }
func (s *stubAdapter) Capabilities() []providers.Capability     { return nil }
func (s *stubAdapter) MetricSupport() []providers.MetricSupport { return nil }
func (s *stubAdapter) ValidateCredentials(context.Context, providers.Account) (*providers.ValidationReport, error) {
	return nil, nil
}
func (s *stubAdapter) Discover(_ context.Context, acct providers.Account) ([]model.DiscoveredResource, error) {
	if acct.Credentials["client_secret"] != "s3cr3t" {
		return nil, fmt.Errorf("%w: wrong secret", providers.ErrInvalidCreds)
	}
	return s.resources, nil
}
func (s *stubAdapter) CollectMetrics(_ context.Context, _ providers.Account, refs []model.ResourceRef, _, to time.Time) (*providers.MetricsResult, error) {
	r := providers.NewMetricsResult()
	if s.metricErr != nil {
		return r, s.metricErr
	}
	for _, ref := range refs {
		r.Add(ref.ID, model.Sample{Metric: "cpu.utilization", TS: to.Add(-time.Minute), Value: 12})
		r.MarkUnavailable(ref.ID, "memory.utilization", "requires guest agent")
	}
	return r, nil
}
func (s *stubAdapter) CollectHealth(context.Context, providers.Account, []model.ResourceRef) ([]model.HealthObservation, error) {
	return nil, providers.ErrNotSupported
}
func (s *stubAdapter) CollectHeartbeats(context.Context, providers.Account, time.Time) ([]model.HeartbeatObservation, error) {
	return nil, providers.ErrNotSupported
}
func (s *stubAdapter) CollectEvents(context.Context, providers.Account, time.Time) ([]model.Event, error) {
	return nil, nil
}

func TestCollectorLifecycle(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	kr, _ := secrets.NewLocalKeyring("v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
	var org, acct string
	if err := pool.QueryRow(ctx, `INSERT INTO organizations(name, slug) VALUES ('o','org-o') RETURNING id`).Scan(&org); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO cloud_accounts(id, org_id, provider, name, auth_method, status)
		VALUES (gen_random_uuid(), $1, 'azure', 'a', 'client_secret', 'active') RETURNING id`, org).Scan(&acct); err != nil {
		t.Fatal(err)
	}
	setSecret := func(secret string) {
		doc, _ := json.Marshal(map[string]string{"client_secret": secret})
		blob, err := secrets.Seal(ctx, kr, doc, secrets.CloudAccountAAD(org, acct))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `UPDATE cloud_accounts SET credential_ciphertext=$2 WHERE id=$1`, acct, blob); err != nil {
			t.Fatal(err)
		}
	}
	setSecret("s3cr3t")
	stub := &stubAdapter{resources: []model.DiscoveredResource{
		{ProviderResourceID: "/vm/a", Name: "a", Type: model.TypeVM, PowerState: model.PowerRunning, Tags: map[string]string{"env": "prod"}},
		{ProviderResourceID: "/vm/b", Name: "b", Type: model.TypeVM, PowerState: model.PowerStopped},
	}}
	s := New(pool, kr, []providers.Adapter{stub}, Config{InstanceID: "t"}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := s.EnsureJobs(ctx); err != nil {
		t.Fatal(err)
	}
	run := func(kind string) (string, int) {
		var j job
		var iv int
		if err := pool.QueryRow(ctx, `SELECT id, org_id, cloud_account_id, kind, interval_seconds, consecutive_failures FROM collection_jobs WHERE kind=$1`, kind).
			Scan(&j.ID, &j.OrgID, &j.AccountID, &j.Kind, &iv, &j.Failures); err != nil {
			t.Fatal(err)
		}
		j.Interval = time.Duration(iv) * time.Second
		s.runJob(ctx, j)
		var status string
		var failures int
		_ = pool.QueryRow(ctx, `SELECT last_status, consecutive_failures FROM collection_jobs WHERE id=$1`, j.ID).Scan(&status, &failures)
		return status, failures
	}

	if st, _ := run("discovery"); st != "ok" {
		t.Fatalf("discovery status %s", st)
	}
	var n int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM resources WHERE org_id=$1 AND deleted_at IS NULL`, org).Scan(&n)
	if n != 2 {
		t.Fatalf("expected 2 resources, got %d", n)
	}
	if st, _ := run("metrics"); st != "ok" {
		t.Fatalf("metrics status %s", st)
	}
	var gaps string
	_ = pool.QueryRow(ctx, `SELECT metric_gaps->>'memory.utilization' FROM resources WHERE provider_resource_id='/vm/a'`).Scan(&gaps)
	if gaps != "requires guest agent" {
		t.Fatalf("metric gap not recorded: %q", gaps)
	}
	if st, _ := run("health"); st != "skipped" {
		t.Fatalf("unsupported capability must be 'skipped', got %s", st)
	}

	// Resource b disappears from discovery: soft-deleted, not hard-deleted.
	stub.resources = stub.resources[:1]
	run("discovery")
	var deleted int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM resources WHERE deleted_at IS NOT NULL`).Scan(&deleted)
	if deleted != 1 {
		t.Fatalf("missing resource should be soft-deleted")
	}

	// Throttling backs off and is counted, without touching resources.
	stub.metricErr = &providers.ThrottledError{RetryAfter: 10 * time.Minute, Detail: "429"}
	st, _ := run("metrics")
	var next time.Time
	_ = pool.QueryRow(ctx, `SELECT next_run_at FROM collection_jobs WHERE kind='metrics'`).Scan(&next)
	if st != "throttled" || time.Until(next) < 9*time.Minute {
		t.Fatalf("throttled job must honour Retry-After: %s next in %s", st, time.Until(next))
	}

	// Credential failure marks the account in error, never the resources.
	setSecret("rotated-elsewhere")
	if st, _ := run("discovery"); st != "error" {
		t.Fatalf("expected error, got %s", st)
	}
	var acctStatus string
	_ = pool.QueryRow(ctx, `SELECT status FROM cloud_accounts WHERE id=$1`, acct).Scan(&acctStatus)
	if acctStatus != "error" {
		t.Fatalf("account should be in error, got %s", acctStatus)
	}
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM resources WHERE deleted_at IS NULL`).Scan(&n)
	if n != 1 {
		t.Fatalf("failed discovery must not delete resources")
	}

	// A ciphertext moved to another org's account cannot be decrypted.
	var other string
	_ = pool.QueryRow(ctx, `INSERT INTO organizations(name, slug) VALUES ('p','org-p') RETURNING id`).Scan(&other)
	if _, _, err := s.LoadAccount(ctx, other, acct); err == nil {
		t.Fatal("account must not load under a different org")
	}
}
