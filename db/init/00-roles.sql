-- Run once per cluster as a superuser (docker-compose runs it automatically).
-- Passwords here are for LOCAL DEVELOPMENT ONLY; production roles are provisioned by
-- Terraform with generated secrets stored in the key vault.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skywatch_api') THEN
    CREATE ROLE skywatch_api LOGIN PASSWORD 'skywatch_api_dev' NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skywatch_worker') THEN
    CREATE ROLE skywatch_worker LOGIN PASSWORD 'skywatch_worker_dev' BYPASSRLS;
  END IF;
END $$;
