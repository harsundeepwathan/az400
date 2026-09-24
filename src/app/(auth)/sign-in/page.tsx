import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getCurrentUser } from "@/lib/auth";
import { env } from "@/lib/env";
import { signInAction } from "../actions";
import { AuthForm } from "../auth-form";

export const metadata: Metadata = { title: "Sign in" };

export default async function SignInPage({ searchParams }: { searchParams: Promise<{ next?: string }> }) {
  if (await getCurrentUser()) redirect("/today");
  const { next } = await searchParams;
  const showDemo = env().AUTH_MODE === "local" && env().NODE_ENV !== "production";
  return (
    <>
      <h1 className="mb-1 text-xl font-semibold">Sign in</h1>
      <p className="mb-5 text-sm text-muted">Welcome back. Pick up where you left off.</p>
      <AuthForm mode="sign-in" action={signInAction} next={next} />
      {showDemo && (
        <p className="mt-5 rounded-md bg-subtle p-3 text-xs text-muted">
          Local demo: after <code>npm run db:seed</code>, sign in as <strong>demo@jobpilot.local</strong> with password{" "}
          <strong>demo-password-123</strong>.
        </p>
      )}
    </>
  );
}
