# ADR-0002: PostgreSQL as the only stateful dependency for the MVP

**Status:** accepted

**Context.** The suggested stack includes TimescaleDB, Redis and NATS JetStream. Each
adds operations burden. The spec says "do not introduce every component immediately".

**Decision.**
- **Telemetry:** native declarative partitioning (daily) with hourly rollups and partition-drop retention. The `tsdb` package is the only writer, so swapping in TimescaleDB hypertables or a remote-write TSDB is local.
- **Queues and scheduling:** tables with `FOR UPDATE SKIP LOCKED` leases (`collection_jobs`, `notification_deliveries`, `synthetic_checks`). These are durable, transactional with the state they change, and need no extra infrastructure.
- **Leader election:** PostgreSQL advisory locks.
- **Caching and rate limits:** in-process (per-instance rate limiting is an accepted MVP limitation).

**Revisit when** sustained ingest exceeds about 20k samples/s, cross-instance rate
limiting is required, or ingest needs buffering through DB maintenance windows. Then
introduce NATS JetStream between ingest and writer.
