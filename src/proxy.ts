import { NextResponse, type NextRequest } from "next/server";
import { createServerClient } from "@supabase/ssr";

const PROTECTED_PREFIXES = [
  "/today", "/onboarding", "/jobs", "/applications", "/resumes", "/evidence",
  "/interviews", "/analytics", "/reminders", "/settings", "/print", "/api/export",
];

/**
 * Optimistic route protection plus Supabase session refresh. This only checks
 * that a session cookie is present; every page, action and route handler
 * still validates the session server-side via requireUser().
 */
export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });
  let hasSession: boolean;

  if (process.env.AUTH_MODE === "supabase") {
    const supabase = createServerClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      {
        cookies: {
          getAll: () => request.cookies.getAll(),
          setAll: (toSet) => {
            for (const { name, value } of toSet) request.cookies.set(name, value);
            response = NextResponse.next({ request });
            for (const { name, value, options } of toSet) response.cookies.set(name, value, options);
          },
        },
      },
    );
    const { data } = await supabase.auth.getClaims();
    hasSession = Boolean(data?.claims?.sub);
  } else {
    hasSession = request.cookies.has("jp_session");
  }

  const path = request.nextUrl.pathname;
  const isProtected = PROTECTED_PREFIXES.some((p) => path === p || path.startsWith(`${p}/`));
  if (isProtected && !hasSession) {
    const url = request.nextUrl.clone();
    url.pathname = "/sign-in";
    url.search = "";
    url.searchParams.set("next", path);
    return NextResponse.redirect(url);
  }
  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|icon.svg|robots.txt).*)"],
};
