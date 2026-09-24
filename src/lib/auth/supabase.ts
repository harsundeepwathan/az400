import "server-only";
import { createServerClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { env } from "../env";
import { withAdmin } from "../db";
import type { AuthResult, SessionUser } from "./types";

export async function supabaseServerClient() {
  const cookieStore = await cookies();
  const e = env();
  return createServerClient(e.NEXT_PUBLIC_SUPABASE_URL!, e.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (toSet) => {
        try {
          for (const { name, value, options } of toSet) cookieStore.set(name, value, options);
        } catch {
          // Called from a Server Component; the proxy refreshes cookies instead.
        }
      },
    },
  });
}

export async function supabaseGetUser(): Promise<SessionUser | null> {
  const supabase = await supabaseServerClient();
  // getUser() validates the token with Supabase Auth rather than trusting the cookie.
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return null;
  return { id: data.user.id, email: data.user.email ?? "" };
}

export async function supabaseSignIn(email: string, password: string): Promise<AuthResult> {
  const supabase = await supabaseServerClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  return error ? { ok: false, error: "Incorrect email or password." } : { ok: true };
}

export async function supabaseSignUp(email: string, password: string): Promise<AuthResult> {
  const supabase = await supabaseServerClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: { emailRedirectTo: `${env().APP_URL}/auth/callback` },
  });
  if (error) return { ok: false, error: error.message };
  if (!data.session) return { ok: true, message: "Check your email to confirm your account, then sign in." };
  return { ok: true };
}

export async function supabaseSignOut() {
  const supabase = await supabaseServerClient();
  await supabase.auth.signOut();
}

export async function supabaseDeleteUser(userId: string) {
  const e = env();
  if (e.SUPABASE_SERVICE_ROLE_KEY) {
    const admin = createClient(e.NEXT_PUBLIC_SUPABASE_URL!, e.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) throw new Error("Account deletion failed");
  } else {
    // The database owner connection may delete from auth.users; cascades remove all data.
    await withAdmin((db) => db.query("delete from auth.users where id = $1", [userId]));
  }
  await supabaseSignOut().catch(() => undefined);
}
