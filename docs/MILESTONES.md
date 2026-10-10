# MVP scope and milestones

| Phase | Scope | Status |
|---|---|---|
| 1. Foundation | Monorepo, schema and migrations, RLS, auth (OIDC and local dev), organizations, RBAC, design system, cloud account model, compose, seeded demo | ✅ Done |
| 2. Azure | Entra auth (secret, certificate, managed identity), Resource Graph discovery, power state, Monitor metrics, Resource Health, Activity Log, Log Analytics heartbeat | ✅ Implemented and contract-tested · ⏳ live verification needs credentials |
| 3. Core monitoring | Scheduler, heartbeat state machine, metric ingestion, partitioned storage and rollups, charts, alert engine, incidents, escalation, notifications | ✅ Done |
| 4. Agent | Go agent (Linux and Windows), systemd and SCM services, secure enrollment and rotation, ingest API v1 | ✅ Done (Windows runtime unverified) |
| 5. More providers | DigitalOcean (full MVP scope), Alibaba ECS and CloudMonitor | ✅ Implemented · Alibaba RDS/SLB/OSS ❌ not implemented |
| 6. Advanced | Synthetic monitoring, escalation, NOC wallboard, disk forecast (linear), reports (CSV/PDF), maintenance windows, correlation | ✅ Done (forecast experimental) |

## Next milestones (proposed order)

1. **Live verification** of the three providers (see LIVE_VERIFICATION.md) and resolution of the experimental flags (DigitalOcean bandwidth unit, Alibaba disk dimension).
2. **Key Vault `KeyProvider`** to replace the environment keyring in production.
3. **Private probe enrollment API**: probes pull checks over HTTPS with a probe credential instead of a DB DSN.
4. **Azure batch metrics API** for estates with more than 1,000 resources.
5. Alibaba RDS, SLB and OSS; then AWS (EC2, CloudWatch, Health) and GCP (Compute, Cloud Monitoring).
6. Kubernetes manifests and Helm chart.
7. Agent mTLS option and signed release artifacts (cosign) with an update channel.
