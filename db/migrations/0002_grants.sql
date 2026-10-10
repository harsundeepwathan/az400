-- Grants for the runtime roles. Roles are created out-of-band (db/init/00-roles.sql or
-- Terraform); if they do not exist yet this migration is a no-op for that role.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skywatch_api') THEN
    GRANT USAGE ON SCHEMA public TO skywatch_api;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO skywatch_api;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO skywatch_api;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO skywatch_api;
    -- The API never deletes audit records.
    REVOKE UPDATE, DELETE ON audit_logs FROM skywatch_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO skywatch_api;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO skywatch_api;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skywatch_worker') THEN
    GRANT USAGE ON SCHEMA public TO skywatch_worker;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO skywatch_worker;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO skywatch_worker;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO skywatch_worker;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO skywatch_worker;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO skywatch_worker;
  END IF;
END $$;
