# ADR-0001: One Go binary with roles, one TypeScript API, one UI

**Status:** accepted

**Context.** The spec asks for Go monitoring services, a TypeScript management API and
modular, economical deployment that avoids microservice sprawl.

**Decision.**
- Monitoring workloads (collection, ingestion, evaluation, notification, probing, data lifecycle) live in **one Go binary**, enabled per process with `--roles`.
- The **management API** (TypeScript, Fastify) owns user-facing concerns: authN/Z, CRUD, reports.
- The two share PostgreSQL, plus an internal control endpoint for provider operations that only Go can perform: validate, discover, test-send.

**Consequences.** A small install is three processes plus PostgreSQL. Roles scale
independently by running more instances with a subset of roles. The cost is one schema
used from two languages: migrations are SQL-first, and the shared crypto, password and
token formats carry cross-language tests.
