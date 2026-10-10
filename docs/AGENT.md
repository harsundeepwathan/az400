# Skywatch agent

A single static Go binary for **Windows Server** and **Linux** (Ubuntu, Debian,
RHEL-compatible).

| Property | Value |
|---|---|
| Network | Outbound HTTPS only (TLS ≥ 1.2, optional custom CA, honours `HTTPS_PROXY`). **No listening ports.** |
| Commands | None. The server can change collection intervals and the watched-service list, nothing else. |
| Collects | Heartbeat, CPU (total, per core, iowait, steal, load), memory and swap, **every real mounted filesystem**, disk and network rates, TCP connections, uptime, OS identity, service states, agent self-health |
| Never collects | Process command lines, environment variables, file contents, credentials |
| Identity | Enrollment token → agent ID + 256-bit secret (stored 0600). Rotated automatically every 30 days with a 15-minute overlap for the previous secret |
| Resilience | Bounded in-memory queue (default 720 batches ≈ 12 h). The oldest data is dropped first and the drops are reported. Exponential backoff with jitter. Honours `Retry-After`. Batches are idempotent (UUID) |
| Footprint | Typically < 1% CPU and < 50 MB RSS. The systemd unit enforces `CPUQuota=10%` and `MemoryMax=128M` |

## Install

Create a token in **Agents → Create enrollment token** (single-use by default, expiring).
The UI prints the commands.

**Linux** (as root):
```bash
sudo SKYWATCH_SERVER=https://ingest.example.com SKYWATCH_ENROLLMENT_TOKEN=swe_… ./install.sh ./skywatch-agent
```
This creates the `skywatch-agent` system user, installs the binary and a hardened systemd
unit (`deploy/agent/skywatch-agent.service`), enrolls, and starts the service.

**Windows** (PowerShell as Administrator):
```powershell
$env:SKYWATCH_ENROLLMENT_TOKEN = 'swe_…'
.\install.ps1 -Server https://ingest.example.com -Binary .\skywatch-agent.exe
```
This installs to `C:\Program Files\Skywatch`, restricts `C:\ProgramData\Skywatch` to
SYSTEM and Administrators, and registers the `SkywatchAgent` service with restart-on-failure.

The token is passed through the environment, so it never appears in the process list
or shell history.

### Cloud linking
At enrollment the agent reads the local metadata service:
- Azure IMDS `compute.resourceId`
- DigitalOcean `/metadata/v1/id`
- Alibaba `100.100.100.200/latest/meta-data/instance-id`

Its data then attaches to the VM that cloud discovery found, so provider and guest
signals combine on one resource. On-premises hosts are identified by `/etc/machine-id`
or the Windows `MachineGuid`, so a reinstall re-attaches to the same record. Disable this
with `--no-cloud-metadata`.

## Services
- **Linux:** `systemctl show` with fixed arguments, no shell. Reports `ActiveState`, `SubState`, `MainPID`, `NRestarts` and `UnitFileState`.
- **Windows:** the Service Control Manager, opened with `SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG` only. Reports state, PID and startup type (automatic, delayed, manual, disabled).
- Watched services are reported every cycle. A full inventory is sent every 15 minutes, as informational.
- An alert fires only for services an operator marked **required** (on the server page or in the monitoring policy). A stopped manual-start service never alerts on its own.

## Upgrade
Replace the binary and restart the service (`systemctl restart skywatch-agent` /
`Restart-Service SkywatchAgent`). The identity in `state.json` is preserved. The agent
reports its version, and the **Monitoring health** page lists versions in the fleet.

## Uninstall
`deploy/agent/uninstall.sh` or `uninstall.ps1` stops the service and removes the binary
and local identity. Then **revoke** the agent in the UI so Skywatch stops expecting
heartbeats. Until you revoke it, the host correctly shows a missing heartbeat.

## Configuration (`/etc/skywatch-agent/config.json`)

```json
{
  "server_url": "https://ingest.example.com",
  "ca_file": "/etc/skywatch-agent/ca.pem",
  "exclude_mounts": ["/mnt/scratch*"],
  "watch_services": ["nginx.service"],
  "queue_size": 720
}
```
