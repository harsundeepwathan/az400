# Monitoring signals and state model

Implementation: `go/internal/health/health.go` (decision table, tested in
`health_test.go`), `go/internal/alerting/rules.go` (alert lifecycle).

## Two separate axes

| Axis | Values | Source |
|---|---|---|
| **Power state** (provider-reported) | running, stopped, deallocated, starting, stopping, provisioning, deleting, unknown, not_applicable | Azure instance view / Resource Graph, Droplet status, ECS status |
| **Operational state** (Skywatch-computed) | healthy, warning, critical, down, stopped, unknown, maintenance, no_data | Evaluator, every 30 s |

"Running" is a power state. It never implies the OS or workload is healthy.

## Signals

| # | Signal | Origin | Trusted when |
|---|---|---|---|
| 1 | Power/provisioning state | Provider discovery | Integration healthy |
| 2 | Provider health (Azure Resource Health, ECS HealthStatus) | Provider | Fresh (≤ 20 min) and integration healthy |
| 3 | Skywatch agent heartbeat | Agent → ingest | Ingest pipeline healthy |
| 4 | Provider guest heartbeat (Azure Monitor Agent `Heartbeat` table) | Log Analytics | Integration healthy |
| 5 | Reachability checks (TCP, HTTP, ICMP) linked with *counts for liveness* | Probes | Result fresher than 3 × interval |
| 6 | Required services | Agent | Report fresher than 3 × heartbeat interval |
| 7 | Firing metric and synthetic alerts | Evaluator | Data fresher than 15 min |

## Heartbeat classification

Defaults (organization monitoring policy, configurable): interval 60 s, warning 120 s,
critical 300 s.

| Age since last heartbeat | Status |
|---|---|
| < warning | ok |
| warning … critical | late (→ Warning) |
| ≥ critical | missing |
| none yet | never (→ No data) |

`missed = floor(age / interval) − 1`. Heartbeats from the future (clock skew) count as
fresh. Latency is `received_at − sent_at`, clamped at 0.

## Decision table (first matching row wins)

| Condition | State | Reason shown |
|---|---|---|
| In an active maintenance window | **maintenance** | window name |
| Provider says stopped/deallocated, no fresh heartbeat, integration healthy | **stopped** | provider state |
| Provider health *Unavailable* (fresh, integration healthy) | **down** (confirmed) | provider reason |
| Heartbeat missing **and** every linked reachability check failing | **down** (confirmed) | both signals |
| Heartbeat missing, a reachability check passing | **critical**, *agent problem* | "monitoring agent problem" |
| Heartbeat missing, no independent check | **critical**, *host status unconfirmed* | explicit |
| Required critical service not in expected state / critical alert | **critical** | finding |
| Heartbeat late, warning alert, provider *Degraded*, non-critical service, partial check failure, transitional power state | **warning** | finding |
| No findings but a positive fresh signal | **healthy** (noting when OS responsiveness is unverified) | |
| No findings, integration degraded, no other signal | **unknown** ("Monitoring degraded") | integration error |
| No findings, ingest pipeline degraded | **unknown** | |
| Nothing at all | **no_data** | |

All findings are stored in `resources.signals.reasons`, so the UI shows every
contributing problem, not just the worst one.

### Monitoring failures are not outages

- A failing cloud integration (auth error, permission loss, three consecutive failures, throttling) sets the account to *error* or *degraded*. It opens one "Monitoring degraded" incident for the account. Provider-derived signals become untrusted, and affected resources become **unknown**. They never become **down**.
- If no `ingest` instance is alive, or every agent stops heartbeating at once, `IngestDegraded` is set. Heartbeat rules hold their state and do not fire.

## Flapping

The number of state changes inside `flap_window_s` (default 15 min) is compared with
`flap_threshold` (default 4). A flapping resource is marked and the reason is annotated.
Incidents that auto-resolved less than 10 minutes ago are **reopened** instead of
duplicated.

## Alert lifecycle

```
normal ──breach──▶ pending ──sustained for ≥ for_seconds and ≥ consecutive──▶ firing
   ▲                  │                                                       │
   └──── ok ──────────┘                                past recovery threshold │
                                                                               ▼
                         (incident acknowledged by a human)               resolved
```

- **Evaluation uses data timestamps**, so lagging provider metrics are judged correctly. A data gap of more than 3 minutes breaks a "sustained" run.
- **No data never changes state.** Stale series (> 15 min old) hold their current state. Alerts resolve only on a recovered sample, or when their subject no longer exists (resource deleted or powered off, rule disabled, service no longer required).
- **Hysteresis.** `recovery_threshold` (for example CPU fires above 85 and clears below 80).
- **Maintenance.** Resources in a window cannot enter *firing*.
- **Acknowledged** is an incident state, not an alert state.

## Incidents

- **Grouping.** One open incident per resource (`dedup_key = resource:<id>`). Further alerts attach to it and can raise severity. A unique partial index guarantees deduplication.
- **Relationship correlation.** A new incident is linked as a child when a related resource already has one (`depends_on`, `member_of`, `attached_to`, or LB `backend_of`). Child notifications are suppressed. The note states that this is correlation, not a confirmed root cause.
- **Burst correlation.** Three or more incidents in the same account and region within 5 minutes are grouped under one "Multiple resources affected" parent.
- **Resolution.** Automatic when every attached alert is resolved. Manual resolve is possible; still-firing alerts then do not reopen the incident until they clear and fire again.
- **Escalation.** Steps (`delay_seconds`, `channel_ids`), optional repeat interval and recovery notifications. Escalation stops on acknowledgement.

## Availability

Implemented twice with identical tests: `go/internal/health/availability.go` and
`apps/api/src/lib/availability.ts`.

```
available   = time in healthy, warning, critical
unavailable = time in down
excluded    = maintenance, stopped, unknown, no_data, and unobserved time
availability % = available / (available + unavailable)      (null if nothing observed)
coverage      = (available + unavailable) / period
```

The strict policy (`critical_is_down=true`) also counts *critical* as unavailable, for
SLOs that treat degraded service as an outage. Stopped time is excluded by default
because powering off is intentional; `StoppedIsDown` exists for policies that disagree.
Reports print this methodology on every export.
