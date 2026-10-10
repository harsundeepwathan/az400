# ADR-0003: Enforce tenant isolation with PostgreSQL row-level security

**Status:** accepted

**Decision.**
- Every tenant table has `org_id` and an RLS policy `org_id = app_org_id()` with `FORCE ROW LEVEL SECURITY`.
- The API connects as `skywatch_api` (no `BYPASSRLS`) and sets `app.org_id` and `app.user_id` with `set_config(..., true)` per transaction, so a pooled connection cannot leak scope.
- `users` and `sessions` are also RLS-protected. Pre-authentication lookups (login, OIDC subject, session token) go through SECURITY DEFINER functions that return only the needed fields.
- Workers use `skywatch_worker` (`BYPASSRLS`) and always filter by `org_id` explicitly.

**Consequences.** An authorization bug in the API cannot read or write another
tenant's rows. Tests assert this with raw queries.
