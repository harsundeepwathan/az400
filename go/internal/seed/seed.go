// Package seed creates the demonstration environment: a clearly labelled demo
// organization with synthetic cloud accounts, plus an empty second organization used
// to demonstrate tenant isolation.
package seed

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/passwords"
)

// Result lists created credentials (development only).
type Result struct {
	DemoOrgID string
	Users     []string
}

type user struct{ email, name, role, org string }

// Demo seeds idempotently. password is used for all seeded local users.
func Demo(ctx context.Context, pool *pgxpool.Pool, password string) (*Result, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	orgs := map[string]string{}
	for _, o := range []struct {
		slug, name string
		demo       bool
	}{{"northwind-demo", "Northwind Ops (Demo)", true}, {"acme", "Acme Infrastructure", false}} {
		var id string
		err := tx.QueryRow(ctx, `INSERT INTO organizations(name, slug, is_demo) VALUES ($1,$2,$3)
			ON CONFLICT (slug) DO UPDATE SET name=EXCLUDED.name RETURNING id`, o.name, o.slug, o.demo).Scan(&id)
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `SELECT skywatch_init_org($1)`, id); err != nil {
			return nil, err
		}
		orgs[o.slug] = id
	}
	hash, err := passwords.Hash(password)
	if err != nil {
		return nil, err
	}
	res := &Result{DemoOrgID: orgs["northwind-demo"]}
	for _, u := range []user{
		{"admin@demo.local", "Dana Admin", "org_admin", "northwind-demo"},
		{"infra@demo.local", "Ira Infra", "infra_admin", "northwind-demo"},
		{"operator@demo.local", "Omar Operator", "operator", "northwind-demo"},
		{"viewer@demo.local", "Vic Viewer", "viewer", "northwind-demo"},
		{"admin@acme.local", "Alex Acme", "org_admin", "acme"},
	} {
		var uid string
		err := tx.QueryRow(ctx, `INSERT INTO users(email, display_name, password_hash) VALUES ($1,$2,$3)
			ON CONFLICT (lower(email)) DO UPDATE SET display_name=EXCLUDED.display_name, password_hash=EXCLUDED.password_hash
			RETURNING id`, u.email, u.name, hash).Scan(&uid)
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO memberships(org_id, user_id, role) VALUES ($1,$2,$3)
			ON CONFLICT (org_id, user_id) DO UPDATE SET role=EXCLUDED.role`, orgs[u.org], uid, u.role); err != nil {
			return nil, err
		}
		res.Users = append(res.Users, fmt.Sprintf("%s (%s, %s)", u.email, u.role, u.org))
	}
	demo := orgs["northwind-demo"]
	for _, a := range []struct{ provider, name, ext string }{
		{"azure", "Azure — Production (demo)", "00000000-0000-0000-0000-00000000d3m0"},
		{"digitalocean", "DigitalOcean — Edge (demo)", "demo-team"},
		{"alibaba", "Alibaba Cloud — APAC (demo)", "demo-uid"},
	} {
		if _, err := tx.Exec(ctx, `INSERT INTO cloud_accounts(org_id, provider, name, external_id, auth_method, status, credential_hint, last_validated_at)
			SELECT $1,$2,$3,$4,'demo','active','synthetic data — no credentials', now()
			WHERE NOT EXISTS (SELECT 1 FROM cloud_accounts WHERE org_id=$1 AND provider=$2 AND auth_method='demo')`,
			demo, a.provider, a.name, a.ext); err != nil {
			return nil, err
		}
	}
	// A required-service scenario and a synthetic check for the demo org.
	if _, err := tx.Exec(ctx, `INSERT INTO synthetic_checks(org_id, name, kind, target, config, interval_seconds)
		SELECT $1, 'Public status page (example.com)', 'http', 'https://example.com/', '{"expected_status":[200]}', 300
		WHERE NOT EXISTS (SELECT 1 FROM synthetic_checks WHERE org_id=$1)`, demo); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return res, nil
}

// demoServices are reported for demo VMs by SimulateServices. One required service is
// stopped so the "required service stopped" workflow is visible in the demo.
var demoServices = []struct{ vm, platform, name, display, state, expected string }{
	{"web-prod-01", "systemd", "nginx.service", "nginx", "running", "running"},
	{"web-prod-02", "systemd", "nginx.service", "nginx", "running", "running"},
	{"web-prod-01", "systemd", "sshd.service", "OpenSSH server", "running", "running"},
	{"api-prod-01", "systemd", "orders-api.service", "Orders API", "running", "running"},
	{"api-prod-01", "systemd", "redis-server.service", "Redis", "failed", "running"},
	{"sql-prod-01", "windows", "MSSQLSERVER", "SQL Server (MSSQLSERVER)", "running", "running"},
	{"sql-prod-01", "windows", "SQLSERVERAGENT", "SQL Server Agent (MSSQLSERVER)", "running", "running"},
	{"dc-01", "windows", "DNS", "DNS Server", "running", "running"},
	{"dc-01", "windows", "wuauserv", "Windows Update", "stopped", "any"},
	{"edge-ams3-01", "systemd", "docker.service", "Docker", "running", "running"},
}

// SimulateServices refreshes synthetic service states for the demo organization.
func SimulateServices(ctx context.Context, pool *pgxpool.Pool) error {
	for _, s := range demoServices {
		_, err := pool.Exec(ctx, `INSERT INTO service_checks(org_id, resource_id, platform, name, display_name, expected_state, critical,
				startup_type, current_state, last_reported_at, last_change_at, discovered)
			SELECT r.org_id, r.id, $2, $3, $4, $6, $6 = 'running', CASE WHEN $2 = 'windows' THEN 'automatic' ELSE 'enabled' END, $5, now(), now(), false
			FROM resources r JOIN organizations o ON o.id = r.org_id
			WHERE o.is_demo AND r.name = $1 AND r.deleted_at IS NULL
			ON CONFLICT (resource_id, platform, name) DO UPDATE SET current_state = EXCLUDED.current_state, last_reported_at = now()`,
			s.vm, s.platform, s.name, s.display, s.state, s.expected)
		if err != nil {
			return err
		}
	}
	return nil
}
