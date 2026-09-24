"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { signIn, signOut, signUp } from "@/lib/auth";
import { fieldErrors, str, type ActionState } from "@/lib/forms";
import { takeToken } from "@/lib/rate-limit";
import { credentialsSchema } from "@/lib/validation";

function safeNext(value: string): string {
  return value.startsWith("/") && !value.startsWith("//") && !value.startsWith("/\\") ? value : "/today";
}

async function clientKey(email: string) {
  const h = await headers();
  const ip = h.get("x-forwarded-for")?.split(",")[0]?.trim() || h.get("x-real-ip") || "local";
  return `${ip}:${email}`;
}

export async function signInAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const email = str(fd, "email").toLowerCase();
  const password = String(fd.get("password") ?? "");
  if (!email || !password) return { error: "Enter your email and password." };
  if (!takeToken(`signin:${await clientKey(email)}`, 10, 15 * 60_000)) {
    return { error: "Too many sign-in attempts. Wait a few minutes and try again." };
  }
  const result = await signIn(email, password);
  if (!result.ok) return { error: result.error };
  redirect(safeNext(str(fd, "next")));
}

export async function signUpAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const parsed = credentialsSchema.safeParse({ email: str(fd, "email"), password: String(fd.get("password") ?? "") });
  if (!parsed.success) return { fieldErrors: fieldErrors(parsed.error) };
  if (!takeToken(`signup:${await clientKey(parsed.data.email)}`, 5, 60 * 60_000)) {
    return { error: "Too many attempts. Try again later." };
  }
  const result = await signUp(parsed.data.email, parsed.data.password);
  if (!result.ok) return { error: result.error };
  if (result.message) return { ok: true, message: result.message };
  redirect("/onboarding");
}

export async function signOutAction() {
  await signOut();
  redirect("/sign-in");
}
