-- Inviting a user who may already exist in another organization. The API role cannot
-- see users outside its organization (RLS), so lookup-or-create goes through this
-- function, which only returns the user id.
CREATE OR REPLACE FUNCTION skywatch_invite_user(p_email text, p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid;
BEGIN
  IF app_org_id() IS NULL THEN
    RAISE EXCEPTION 'skywatch_invite_user requires an organization scope';
  END IF;
  SELECT id INTO uid FROM users WHERE lower(email) = lower(p_email);
  IF uid IS NULL THEN
    INSERT INTO users(email, display_name) VALUES (p_email, p_name) RETURNING id INTO uid;
  END IF;
  RETURN uid;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skywatch_api') THEN
    GRANT EXECUTE ON FUNCTION skywatch_invite_user(text, text) TO skywatch_api;
  END IF;
END $$;
