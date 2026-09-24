import { AppShell } from "@/components/app-shell";
import { TimeZoneCookie } from "@/components/timezone-cookie";
import { requireOnboardedUser } from "@/lib/session";
import { signOutAction } from "../(auth)/actions";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { user } = await requireOnboardedUser();
  const signOut = (
    <form action={signOutAction}>
      <button type="submit" className="w-full rounded-md px-2.5 py-2 text-left text-sm hover:bg-subtle hover:text-ink">
        Sign out
      </button>
    </form>
  );
  return (
    <AppShell email={user.email} signOut={signOut}>
      <TimeZoneCookie />
      {children}
    </AppShell>
  );
}
