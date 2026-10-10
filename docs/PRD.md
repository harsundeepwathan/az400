# Product requirements: Skywatch

## Problem

Teams that run infrastructure across several clouds and on-premises servers have
fragmented visibility. Each provider console answers "is the VM running?". None answers
the questions that matter during an incident:

- Is the operating system responsive?
- Did a required service stop?
- Is this a host outage or a broken monitoring agent?
- What changed just before?

Generic dashboards make it worse: they show a calm green panel when the data stopped
arriving.

## Users

| Persona | Needs |
|---|---|
| NOC operator | A wall view of what is broken right now, acknowledgement, a clear owner, no alert storms |
| Infrastructure engineer | Per-server depth: CPU, memory, every volume, services, events, history |
| SRE / cloud ops lead | Availability and SLO evidence with documented methodology; noise control |
| MSP administrator | Strict separation between customer organizations, least-privilege onboarding, audit |

## Questions the product must answer

1. Which servers and resources are unhealthy now? (Overview, Inventory sorted by severity)
2. Which are powered on, stopped, unreachable or silent? (separate *power state* and *operational state*)
3. When was the last heartbeat? (Inventory column, server detail, heartbeat history)
4. Which Windows/Linux services stopped unexpectedly? (required-service model, service alerts)
5. Which servers are running out of disk? (per-volume metrics, capacity report with forecast)
6. Which resources show sustained high CPU or memory? (sustained-window rules with hysteresis)
7. Which applications, websites and endpoints are unavailable? (synthetic checks)
8. What incidents are active, for how long, and what triggered them? (incident list and timeline)
9. What changed before a failure? (Activity Log, provider actions and OS events, shown in the incident)
10. What needs attention first? (severity-ordered lists; wallboard)

## Principles

- **Evidence over assumption.** "VM running" never means "healthy". A missing heartbeat alone is never "Down". No data is never "Healthy".
- **Honest gaps.** Unsupported metrics are labelled as unavailable, with the reason.
- **Monitoring path ≠ customer outage.** A failing collector or integration raises a *monitoring degraded* condition, never a resource outage.
- **Quiet by default.** Sustained windows, hysteresis, per-resource grouping, burst correlation, maintenance windows and flap detection.
- **Read-only, least privilege.** No integration needs write access. The agent executes no remote commands.

## Functional scope (MVP)

| Capability | Requirement | Status |
|---|---|---|
| Inventory | Normalized model across providers; filters (provider, account, type, region, tag, environment, state) | Done |
| Health | 8 states: healthy, warning, critical, down, stopped, unknown, maintenance, no data. Multi-signal evaluation | Done |
| Heartbeats | Agent 60 s default; warning at 2 min, critical at 5 min (configurable); missed count; history; latency | Done |
| Metrics | CPU (total and per core), load, memory, swap, per-volume disk, disk I/O, network, TCP | Done (agent); provider metrics per capability matrix |
| Services | Windows SCM and systemd; required vs informational; transitions; restart counts | Done |
| Synthetic | HTTP/HTTPS (status, body), TCP, DNS, TLS expiry; public/private probe scope; SSRF protection | Done (ICMP needs a privileged probe) |
| Alerting | Thresholds, windows, consecutive, hysteresis, scope and exclusions; lifecycle normal → pending → firing → resolved | Done |
| Incidents | Grouping per resource, dedup, reopen-on-flap, relationship and burst correlation, ack, assign, comment, manual and automatic resolve | Done |
| Notifications | Email, Slack, Teams (Workflows), webhook (HMAC-signed), Telegram; escalation steps; repeat; recovery | Done |
| Onboarding | 7-step wizard with permission report and capability disclosure | Done |
| Security | OIDC SSO, RBAC (4 roles), RLS isolation, envelope-encrypted secrets, audit log, CSRF, rate limits | Done |
| Reports | Availability (methodology stated), incidents (MTTA/MTTR), utilization, disk capacity forecast, services, inventory. CSV and PDF | Done |
| Wallboard | Large-screen view with stale-data warning | Done |
| Self-monitoring | Prometheus metrics, instance heartbeats, job and run history, throttle tracking | Done |

## Out of scope for the MVP (tracked in MILESTONES.md)

- AWS, GCP and VMware adapters
- Alibaba RDS/SLB/OSS discovery
- Log search
- APM and tracing
- Remediation actions (any future remediation needs explicit authorization, narrow permissions and auditing)
- Mobile push
- Multi-region active-active control plane

## Non-functional targets

| Target | Initial value |
|---|---|
| Detection latency (agent host) | ≤ 5 min 30 s from last heartbeat to critical (policy-dependent) |
| Detection latency (provider metric) | ≤ provider metric latency + 2 min collection interval + 30 s evaluation |
| Raw metric retention | 30 days; hourly rollups 12 months; incidents and audit retained by policy |
| Footprint | Single node handles about 2,000 agents and 5,000 provider resources (see ARCHITECTURE.md § scaling) |
| Agent overhead | < 1% CPU, < 50 MB RSS typical (systemd unit enforces a 10% CPU and 128 MB memory ceiling) |
