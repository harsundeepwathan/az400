# Acceptance scenarios and live verification

Status key:
- **Verified (local)**: exercised end to end in this repository's development environment against real PostgreSQL, the real backend, API and UI, and, where marked, a real agent on a real Linux host.
- **Automated**: covered by tests that run in CI.
- **Requires credentials**: the code path is implemented and contract-tested with mocks, but has not been run against the real provider. Follow the steps below.

| # | Scenario | Status | Evidence |
|---|---|---|---|
| 1 | Connect a real Azure subscription with read-only credentials | **Requires credentials** | `go/internal/providers/azure/contract_test.go` (validation, permission report) |
| 2 | Discover an Azure VM and display its actual state | **Requires credentials** | contract tests for Resource Graph mapping, pagination, power states |
| 3 | Retrieve real supported CPU metrics | **Requires credentials** | contract tests for the metrics request contract, null handling, unit conversion |
| 4 | Enroll a Linux or Windows agent | **Verified (local)** Linux; Automated | `TestRealAgentEnrollsAndReports`, `TestAgentToIncidentWorkflow`; manual run on the dev container. Windows: binary builds (`GOOS=windows`), not executed here |
| 5 | Show current memory and per-volume disk usage | **Verified (local)** with real host data | the agent on the dev container reported 3 volumes and memory, visible on the server page |
| 6 | Detect a deliberately stopped monitored service | **Automated** | `TestAgentToIncidentWorkflow` (service `failed` → critical, joins incident). The dev container has no systemd as PID 1, so the agent correctly reports the services collector as failing |
| 7 | Detect a missing heartbeat without declaring a confirmed outage | **Automated** + **Verified (local)** | the workflow test asserts *critical / host status unconfirmed* and `host_confirmed_down=false`, and *down* only after a failing liveness check. The e2e test checks the UI |
| 8 | Trigger a disk or CPU threshold alert | **Verified (local)** with real host data; Automated | a real 91% volume on the dev container raised *Disk space critical*; also integration tests |
| 9 | Generate and acknowledge an incident | **Automated** | API, integration and e2e (`operator acknowledges an incident`) |
| 10 | Recover the service and auto-resolve per policy | **Automated** | the workflow test asserts timeline `opened … resolved` |
| 11 | Connect supported Alibaba Cloud and DigitalOcean accounts | **Requires credentials** | contract tests for both adapters |
| 12 | Show their resources in the same normalized inventory | **Verified (local)** with demo accounts; real accounts require credentials | the demo organization shows Azure, DigitalOcean and Alibaba resources in one inventory |
| 13 | Strict isolation between two customer organizations | **Automated** | API tests: RLS raw-query and IDOR tests; e2e `organizations are isolated` |
| 14 | Graceful handling of missing credentials, missing agents, throttling, unavailable metrics | **Automated** | collector test (auth failure → account error, throttling → back-off honouring Retry-After, ErrNotSupported → skipped); `TestIntegrationFailureDoesNotMarkResourcesDown`; DigitalOcean/Alibaba missing-agent gaps; Azure unsupported-metric gaps |

## Live verification procedure

Run these against real accounts and record the results in the pull request. Use a
throwaway subscription, team or account where possible.

### Azure (scenarios 1–3)
1. Create the identity and role assignments in [onboarding/azure.md](onboarding/azure.md). Deploy one small Linux VM (B1s). Optionally connect it to a Log Analytics workspace with the Azure Monitor Agent and VM Insights.
2. In the Acme organization: **Cloud accounts → Connect → Azure**. Expect every validation check to pass, and the subscription listed under *Authenticated as*.
3. Discover: the VM appears with power state `running`.
4. Activate. Within about 5 minutes:
   - The server page shows CPU, sourced from `azure_monitor`. Compare with the Azure portal *Percentage CPU* chart for the same minutes.
   - With the workspace configured, *Provider guest heartbeat* is `ok`.
5. Stop (deallocate) the VM in the portal. After the next discovery (≤ 5 min) the state is **Stopped**. No heartbeat alert fires.
6. Remove the *Monitoring Reader* assignment and re-validate. The report names the missing permission. The account goes *degraded*, and resources do **not** go down.
7. Confirm in the ARM throttling headers (`x-ms-ratelimit-remaining-subscription-reads`) that polling stays well inside quota.

### DigitalOcean (scenario 11)
1. Create a read-only token ([guide](onboarding/digitalocean.md)), one Droplet without `do-agent`, and one with it.
2. Connect. Validation passes all scopes.
3. Both Droplets appear. The one without the agent shows memory and disk as *unavailable — do-agent not installed*. The other shows values.
4. **Confirm the bandwidth unit.** Compare *Network in* with the DigitalOcean graph (Mbps). If they disagree, fix `dropletMetrics` and drop the *experimental* note.

### Alibaba Cloud (scenario 11)
1. Create the RAM user and policy from [onboarding/alibaba.md](onboarding/alibaba.md), and one ECS instance with the CloudMonitor agent.
2. Connect with the instance's region. Validation passes.
3. The instance appears with status and `HealthStatus`. CPU matches the CloudMonitor console. Check which dimension `diskusage_utilization` uses (device or mountpoint) and adjust the series label if needed.

### Windows agent (scenario 4)
1. On Windows Server 2019 or later, run `install.ps1` with a token.
2. The server page lists C: (and other volumes), memory and CPU.
3. Mark `Spooler` as *Must run (critical)*, then `Stop-Service Spooler`. An incident opens within about 1 minute. `Start-Service Spooler` auto-resolves it.
