-- Defense in depth for identity tables. The API role can only see users that share the
-- active organization (or itself) and only its own sessions. Pre-authentication
-- lookups go through narrow SECURITY DEFINER functions that return exactly the fields
-- needed for that step.

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY user_visibility ON users
  USING (id = app_user_id() OR id IN (SELECT user_id FROM memberships WHERE org_id = app_org_id()))
  WITH CHECK (id = app_user_id() OR app_org_id() IS NOT NULL);

ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions FORCE ROW LEVEL SECURITY;
CREATE POLICY own_sessions ON sessions USING (user_id = app_user_id()) WITH CHECK (user_id = app_user_id());

CREATE OR REPLACE FUNCTION skywatch_login_lookup(p_email text)
RETURNS TABLE (id uuid, password_hash text, disabled boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.id, u.password_hash, u.disabled FROM users u WHERE lower(u.email) = lower(p_email)
$$;

CREATE OR REPLACE FUNCTION skywatch_oidc_lookup(p_issuer text, p_subject text, p_email text)
RETURNS TABLE (id uuid, disabled boolean, linked boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.id, u.disabled, (u.oidc_issuer = p_issuer AND u.oidc_subject = p_subject)
  FROM users u
  WHERE (u.oidc_issuer = p_issuer AND u.oidc_subject = p_subject)
     OR (u.oidc_subject IS NULL AND lower(u.email) = lower(p_email))
  ORDER BY 3 DESC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION skywatch_session_lookup(p_hash bytea)
RETURNS TABLE (user_id uuid, org_id uuid, csrf_token text, expires_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.user_id, s.org_id, s.csrf_token, s.expires_at FROM sessions s
  WHERE s.token_hash = p_hash AND s.expires_at > now()
$$;

-- Organizations a user belongs to, for the org switcher before an org is selected.
CREATE OR REPLACE FUNCTION skywatch_user_orgs(p_user uuid)
RETURNS TABLE (org_id uuid, name text, slug text, is_demo boolean, role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT o.id, o.name, o.slug, o.is_demo, m.role FROM memberships m JOIN organizations o ON o.id = m.org_id
  WHERE m.user_id = p_user ORDER BY o.name
$$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skywatch_api') THEN
    GRANT EXECUTE ON FUNCTION skywatch_login_lookup(text), skywatch_oidc_lookup(text, text, text),
      skywatch_session_lookup(bytea), skywatch_user_orgs(uuid) TO skywatch_api;
  END IF;
END $$;
