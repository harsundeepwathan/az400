# Provider capability matrix

Status legend:
- **Implemented**: real API integration with mocked contract tests.
- **Experimental**: real integration with assumptions to confirm live.
- **Not implemented**: a known gap.
- **Unsupported**: the provider does not expose it.

"Live-verified" means exercised against a real account in this repository's CI or by a
maintainer. **No provider integration is live-verified yet**, because this environment
has no cloud credentials. The procedure is in [LIVE_VERIFICATION.md](LIVE_VERIFICATION.md).
The adapters also report this matrix at runtime (`Capabilities()`), and the onboarding
wizard shows it.

## Inventory and state

| Capability | Azure | DigitalOcean | Alibaba Cloud | Agent (any host) |
|---|---|---|---|---|
| Credential validation with permission report | Implemented | Implemented | Implemented | n/a |
| Multi-account / multi-tenant | Implemented (one account per tenant, N subscriptions) | Implemented (one per token) | Implemented (N regions per account) | Implemented |
| VM discovery and power state | Implemented (Resource Graph `instanceView.powerState`) | Implemented (Droplet `status`) | Implemented (`DescribeInstances`) | Enrolment creates or links the host |
| VM scale sets / node pools | Implemented (VMSS) | Not implemented (DOKS node pools) | Not implemented | n/a |
| App Service / Functions | Implemented | n/a | Not implemented | n/a |
| Managed SQL / DB | Implemented (Azure SQL DB) | Implemented (Managed Databases) | Not implemented (RDS) | n/a |
| Storage | Implemented (Storage accounts) | Implemented (Volumes) | Not implemented (OSS) | n/a |
| Load balancers / gateways | Implemented (LB, App Gateway, VPN GW, Firewall) | Implemented (LB) | Not implemented (SLB) | n/a |
| Kubernetes | Implemented (AKS) | Implemented (DOKS) | Not implemented (ACK) | n/a |
| Relationships for correlation | Implemented (VM → LB via NIC backend pools) | Implemented (Droplet → LB, Volume → Droplet) | Not implemented | n/a |
| Provider health | Implemented (Resource Health) | Unsupported (no per-resource API) | Implemented (ECS `HealthStatus`) | n/a |
| Change events | Implemented (Activity Log incl. Service Health) | Implemented (account actions) | Not implemented (ActionTrail) | Agent OS events: contract only |

## Metrics

| Normalized metric | Azure (platform) | Azure (VM Insights) | DigitalOcean | Alibaba CloudMonitor | Skywatch agent |
|---|---|---|---|---|---|
| `cpu.utilization` | `Percentage CPU` | | `droplet/cpu` (mode counters → %) | `CPUUtilization` | ✓ |
| `cpu.core.utilization` | Unsupported | | Unsupported | Unsupported | ✓ |
| `cpu.load1/5/15` | Unsupported | | `load_1` (do-agent) | `load_1m` (agent) | ✓ (Linux) |
| `memory.utilization` | Unsupported (only *available bytes*) | Experimental | do-agent | `memory_usedutilization` (agent) | ✓ |
| `memory.available_bytes` | `Available Memory Bytes` | Experimental | do-agent | | ✓ |
| `disk.utilization` per volume | Unsupported | Experimental (`FreeSpacePercentage` per mount) | do-agent (per mountpoint) | `diskusage_utilization` (agent, per device) | ✓ every real mount |
| Disk throughput / IOPS | `Disk Read/Write Bytes`, `…Operations/Sec` | | Not implemented | `DiskRead/WriteBPS/IOPS` | ✓ |
| Network throughput | `Network In/Out Total` (÷ interval) | | `bandwidth` public (experimental: Mbps assumed) | `InternetIn/OutRate` (bit/s ÷ 8) | ✓ (+ packets, errors, drops) |
| TCP established | Unsupported | | Unsupported | Unsupported | ✓ (Linux) |
| VM availability | `VmAvailabilityMetric` (optional; reported unavailable if absent) | | | | n/a |
| App / DB / LB / storage KPIs | Http5xx, HttpResponseTime, cpu_percent, storage_percent, VipAvailability, HealthyHostCount, FirewallHealth, Availability, node_cpu/memory (AKS) | | Not implemented | | n/a |
| Guest heartbeat | Azure Monitor Agent `Heartbeat` table | | Unsupported | Unsupported | ✓ (60 s) |
| Service state | Unsupported | | Unsupported | Unsupported | ✓ systemd, Windows SCM |

When a metric is unavailable for a resource, the collector stores the reason in
`resources.metric_gaps`. Examples: "requires guest agent", "do-agent not installed", "no
datapoints returned for this interval", "resource is deallocated". The UI shows that
reason instead of an empty chart or a zero.

## Rate limits and throttling

| Provider | Behaviour |
|---|---|
| Azure | SDK retry policy (3 retries, honours `Retry-After`). A 429 after retries surfaces as `ThrottledError`; the job backs off for at least `Retry-After` and the throttle is counted per account. Metrics fan-out is bounded (8 concurrent per account). |
| DigitalOcean | 5,000 requests/hour per token. Concurrency 4. A 429 uses `RateLimit-Reset`. |
| Alibaba | `Throttling.*` error codes map to `ThrottledError`. CloudMonitor queries batch 50 instances per call. |

Throttling and failures never mark resources down (see STATE_MODEL.md).
