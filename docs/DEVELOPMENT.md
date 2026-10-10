# Development, testing and operations

## Run locally without Docker

Prerequisites: Go 1.26, Node 22, and PostgreSQL 16 on `localhost:5432` with a `postgres`
superuser.

```bash
# 1. Database, roles and schema
psql -U postgres -c 'CREATE DATABASE skywatch'
psql -U postgres -f db/init/00-roles.sql          # dev-only role passwords
cd go && go build -o ../bin/skywatch ./cmd/skywatch && cd ..
SKYWATCH_MIGRATE_DATABASE_URL=postgres://postgres:postgres@127.0.0.1/skywatch ./bin/skywatch migrate

# 2. Shared environment
export SKYWATCH_DATABASE_URL=postgres://skywatch_worker:skywatch_worker_dev@127.0.0.1/skywatch
export SKYWATCH_API_DATABASE_URL=postgres://skywatch_api:skywatch_api_dev@127.0.0.1/skywatch
export SKYWATCH_KEKS="v1:$(openssl rand -base64 32)"   # keep it: encrypted credentials depend on it
export SKYWATCH_CONTROL_TOKEN=$(openssl rand -hex 24)

# 3. Demo data, backend, API, UI
SKYWATCH_DEMO_PASSWORD=choose-one ./bin/skywatch seed-demo
./bin/skywatch serve --roles=collector,evaluator,ingest,notifier,probe,maintenance,demo &
npm ci && npm run dev --workspace apps/api &
npm run dev --workspace apps/web     # http://localhost:3000
```

### Run an agent against the local stack
```bash
cd go && go build -o ../bin/skywatch-agent ./cmd/skywatch-agent && cd ..
# Create a token in the UI (Agents → Create enrollment token), then:
SKYWATCH_ENROLLMENT_TOKEN=swe_… ./bin/skywatch-agent enroll --server http://127.0.0.1:8443 --allow-insecure-http --dir ./.agent
./bin/skywatch-agent run --dir ./.agent
```

## Tests

| Suite | Command | Needs |
|---|---|---|
| Go unit, contract and integration | `cd go && go test -race ./...` | PostgreSQL (`SKYWATCH_TEST_ADMIN_URL`, default `postgres://postgres:postgres@127.0.0.1:5432/postgres`); DB tests skip if it is unreachable |
| API unit and integration | `npm test --workspace apps/api` | same PostgreSQL; the API connects as the RLS-bound `skywatch_api` role |
| End-to-end | `npm run test:e2e --workspace apps/web` | a running, seeded stack at `SKYWATCH_E2E_URL` (default `http://localhost:3000`) and `SKYWATCH_DEMO_PASSWORD` |

What is covered:
- **Provider contract tests** (`go/internal/providers/*/contract_test.go`): a fake HTTP server pins request paths, API versions, parameters, pagination and error mapping, and asserts normalization. This includes null datapoints never becoming zeros, and unsupported metrics being reported as gaps.
- **Agent API contract** (`go/pkg/telemetry/contract_test.go`): Go types ↔ published JSON Schema.
- **Health and alerting decision tables** (`go/internal/health`, `go/internal/alerting`).
- **Workflow integration** (`go/internal/integration`): enroll → telemetry → service stop → disk alert → incident → ack → recovery → auto-resolve; heartbeat loss vs confirmed down; storm grouping; escalation; integration failure; stale data holding alerts. Also a **real agent run** against the ingest API.
- **Tenant isolation and RBAC** (`apps/api/test/api.test.ts`), including raw-SQL RLS checks.

## Configuration reference (backend)

| Variable | Default | Purpose |
|---|---|---|
| `SKYWATCH_DATABASE_URL` | required | worker DSN (`BYPASSRLS` role) |
| `SKYWATCH_MIGRATE_DATABASE_URL` | – | owner/superuser DSN for `migrate` |
| `SKYWATCH_ROLES` | all except `demo` | roles for `serve` |
| `SKYWATCH_KEKS` | required for collector/notifier | key-encryption keys |
| `SKYWATCH_INGEST_ADDR`, `SKYWATCH_TLS_CERT`, `SKYWATCH_TLS_KEY` | `:8443` | agent API (terminate TLS here or at a proxy) |
| `SKYWATCH_TRUST_PROXY` | false | use `X-Forwarded-For` behind a trusted LB |
| `SKYWATCH_METRICS_ADDR` | `:9090` | Prometheus `/metrics`, `/healthz` |
| `SKYWATCH_CONTROL_ADDR`, `SKYWATCH_CONTROL_TOKEN` | `127.0.0.1:8081` | internal control API (enabled only with a token) |
| `SKYWATCH_PROBE_LOCATION`, `SKYWATCH_PROBE_SCOPE`, `SKYWATCH_PROBE_ORG_ID` | `default`, `public` | probe identity; private probes must name one org |
| `SKYWATCH_SMTP_*`, `SKYWATCH_PUBLIC_URL`, `SKYWATCH_NOTIFY_ALLOW_PRIVATE` | – | notifications |

The API's variables are in `apps/api/src/config.ts` and `deploy/.env.example`.

## Operations

- **Backups.** Back up PostgreSQL (PITR on the managed service). Keep KEKs in the key vault: losing them makes stored credentials unrecoverable (re-enter them).
- **Upgrades.** Run `skywatch migrate` (idempotent, advisory-locked), then roll the backend, API and web. Migrations are additive.
- **Retention.** The maintenance role creates partitions 7 days ahead, rolls up hourly, and drops raw partitions older than 30 days. Incidents and audit logs are never deleted automatically.
- **Watch the watcher.** Scrape `/metrics`. Alert on `skywatch_evaluator_cycles_total{outcome="error"}`, `skywatch_queue_depth`, and `skywatch_provider_api_throttled_total`. Run an external uptime check against `/healthz` on ingest and API.
