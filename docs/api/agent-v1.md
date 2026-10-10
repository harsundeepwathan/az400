# Agent telemetry API, version 1

Base URL: the ingest endpoint (for example `https://ingest.example.com`). Types:
`go/pkg/telemetry/v1.go`. JSON Schema: [agent-v1.schema.json](agent-v1.schema.json).
Changes within v1 are additive only; breaking changes get a new path.

Authentication (all endpoints except enroll): `Authorization: Bearer <agent_id>.<agent_secret>`.

| Method and path | Purpose | Responses |
|---|---|---|
| `POST /v1/agent/enroll` | Exchange an enrollment token for an identity | 201 `EnrollResponse`; 400 invalid; 401 token invalid, expired, revoked or exhausted; 429 |
| `POST /v1/agent/telemetry` | Upload a `Batch` | 200 `BatchAck` (`duplicate: true` for a re-sent `batch_id`); 400 malformed JSON or unknown fields; 401; 422 validation; 429 with `Retry-After`; 503 persist failure (retry) |
| `POST /v1/agent/rotate` | Rotate the secret | 200 `RotateResponse` (previous secret valid for 15 min) |
| `GET /v1/agent/config` | Fetch server-driven config | 200 `AgentConfig` |
| `GET /healthz` | Liveness incl. DB | 200 / 503 |

## Limits
- Body ≤ 1 MiB
- ≤ 5,000 samples, ≤ 500 services, ≤ 200 events per batch
- Metric names match `^[a-z][a-z0-9_.]{0,127}$`; series ≤ 256 chars
- Sample timestamps outside `[now − 24h, now + 10m]` are dropped (counted in `accepted`)

## Semantics
- Every accepted batch is a heartbeat. `received_at` is server time and `latency_ms = received_at − sent_at` (≥ 0).
- `seq` is monotonic per agent, for diagnostics. **Idempotency comes from `batch_id`** (kept for 48 h).
- Service states: `running | stopped | failed | starting | stopping | unknown`.
- The ack carries the current `AgentConfig`. Agents apply it on the next cycle.

## Example batch
```json
{
  "version": "1",
  "batch_id": "0b8f0b1e-8a7c-4e3c-9d55-7d1b2c3a4f50",
  "seq": 42,
  "sent_at": "2026-10-10T10:00:00Z",
  "agent": { "version": "1.0.0", "queue_depth": 0, "dropped_batches": 0, "cpu_percent": 0.3, "rss_bytes": 21000000, "uptime_seconds": 86400 },
  "metrics": [
    { "m": "cpu.utilization", "t": "2026-10-10T10:00:00Z", "v": 23.5 },
    { "m": "disk.utilization", "s": "mount=/var", "t": "2026-10-10T10:00:00Z", "v": 81.2 }
  ],
  "services": [
    { "platform": "systemd", "name": "nginx.service", "state": "failed", "sub_state": "failed", "restarts": 3, "startup_type": "enabled" }
  ],
  "partial": [{ "collector": "services", "error": "systemctl: System has not been booted with systemd" }]
}
```
