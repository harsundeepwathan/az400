# Onboarding DigitalOcean

## 1. Create a read-only token

**API → Tokens → Generate New Token → Custom scopes**, read only:

| Scope | Used for |
|---|---|
| `account:read` | validation (identity, team) |
| `droplet:read` | Droplet discovery and status |
| `monitoring:read` | `/v2/monitoring/metrics/droplet/*` |
| `load_balancer:read` | load balancers and backend Droplets |
| `database:read` | managed databases |
| `kubernetes:read` | DOKS clusters |
| `block_storage:read` | volumes and attachments |
| `actions:read` | power, resize and rebuild history (change events) |

Use one token per team. Set an expiry and rotate it with **Rotate credentials** on the
account page.

## 2. Guest metrics

CPU and public bandwidth come from the hypervisor. **Memory, filesystem and load need
the DigitalOcean metrics agent** (`do-agent`) on each Droplet:

```bash
curl -sSL https://repos.insights.digitalocean.com/install.sh | sudo bash
```

When the agent is missing, Skywatch reports *"DigitalOcean metrics agent (do-agent) not
installed or not reporting on this Droplet"* for those metrics. For service monitoring
and per-volume detail beyond the root filesystem, install the Skywatch agent.

## Notes and limits
- DigitalOcean has no per-resource health API, so provider health shows *unknown*. Use the Skywatch agent and synthetic checks for liveness.
- API limit: 5,000 requests per hour per token. Skywatch polls with concurrency 4 and honours `RateLimit-Reset` on 429.
- Bandwidth values are interpreted as Mbps (as charted by DigitalOcean). This is marked experimental until confirmed in live verification.
