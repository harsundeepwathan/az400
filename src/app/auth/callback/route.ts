import { NextResponse, type NextRequest } from "next/server";
import { env } from "@/lib/env";
import { supabaseServerClient } from "@/lib/auth/supabase";

/** Supabase email-confirmation callback: exchanges the one-time code for a session. */
export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");
  if (env().AUTH_MODE === "supabase" && code) {
    const supabase = await supabaseServerClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL("/onboarding", request.url));
  }
  return NextResponse.redirect(new URL("/sign-in", request.url));
}
