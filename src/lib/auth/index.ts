import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { env } from "../env";
import { localDeleteUser, localGetUser, localSignIn, localSignOut, localSignUp } from "./local";
import { supabaseDeleteUser, supabaseGetUser, supabaseSignIn, supabaseSignOut, supabaseSignUp } from "./supabase";
import type { AuthResult, SessionUser } from "./types";

export type { AuthResult, SessionUser };

const isLocal = () => env().AUTH_MODE === "local";

/** The signed-in user for this request, validated server-side. Memoised per request. */
export const getCurrentUser = cache(async (): Promise<SessionUser | null> =>
  isLocal() ? localGetUser() : supabaseGetUser(),
);

export async function requireUser(): Promise<SessionUser> {
  const user = await getCurrentUser();
  if (!user) redirect("/sign-in");
  return user;
}

export const signIn = (email: string, password: string): Promise<AuthResult> =>
  isLocal() ? localSignIn(email, password) : supabaseSignIn(email, password);

export const signUp = (email: string, password: string): Promise<AuthResult> =>
  isLocal() ? localSignUp(email, password) : supabaseSignUp(email, password);

export const signOut = (): Promise<void> => (isLocal() ? localSignOut() : supabaseSignOut());

export const deleteAuthUser = (userId: string): Promise<void> =>
  isLocal() ? localDeleteUser(userId) : supabaseDeleteUser(userId);
