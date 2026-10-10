# ADR-0004: Health is computed from independent evidence

**Status:** accepted

**Decision.**
- Operational state is a pure function of signals (`health.Evaluate`).
- *Down* requires corroboration: provider-reported unavailability, or a missing heartbeat **and** failing independent reachability checks.
- Collection and ingestion failures degrade *monitoring*, never resources.
- Missing or stale data holds alert state and never counts as recovery.

**Consequences.** Fewer false "down" pages. Operators see "host status unconfirmed" and
"monitoring degraded" explicitly, and can link a TCP or HTTP check as a liveness signal
to get confirmed outages.
