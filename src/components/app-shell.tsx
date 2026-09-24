"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState, type ReactNode } from "react";
import {
  ChartColumn, Bell, BriefcaseBusiness, CalendarClock, FileText, Gem, SquareKanban, Menu, Settings, Sun, X,
} from "lucide-react";
import { cn } from "@/lib/cn";

const NAV = [
  { href: "/today", label: "Today", icon: Sun },
  { href: "/jobs", label: "Jobs", icon: BriefcaseBusiness },
  { href: "/applications", label: "Applications", icon: SquareKanban },
  { href: "/interviews", label: "Interviews", icon: CalendarClock },
  { href: "/resumes", label: "Resumes", icon: FileText },
  { href: "/evidence", label: "Evidence vault", icon: Gem },
  { href: "/analytics", label: "Analytics", icon: ChartColumn },
  { href: "/reminders", label: "Reminders", icon: Bell },
  { href: "/settings", label: "Settings", icon: Settings },
];

function NavLinks({ onNavigate }: { onNavigate?: () => void }) {
  const pathname = usePathname();
  return (
    <ul className="space-y-0.5">
      {NAV.map(({ href, label, icon: Icon }) => {
        const active = pathname === href || pathname.startsWith(`${href}/`);
        return (
          <li key={href}>
            <Link
              href={href}
              onClick={onNavigate}
              aria-current={active ? "page" : undefined}
              className={cn(
                "flex items-center gap-2.5 rounded-md px-2.5 py-2 text-sm",
                active ? "bg-accent-soft font-medium text-accent-strong" : "text-muted hover:bg-subtle hover:text-ink",
              )}
            >
              <Icon className="h-4 w-4 shrink-0" aria-hidden />
              {label}
            </Link>
          </li>
        );
      })}
    </ul>
  );
}

export function AppShell({ email, signOut, children }: { email: string; signOut: ReactNode; children: ReactNode }) {
  const [open, setOpen] = useState(false);

  return (
    <div className="min-h-screen lg:flex">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded focus:bg-surface focus:px-3 focus:py-2">
        Skip to content
      </a>

      <header className="no-print sticky top-0 z-30 flex h-14 items-center justify-between border-b border-line bg-surface px-4 lg:hidden">
        <Link href="/today" className="font-semibold">JobPilot</Link>
        <button
          type="button"
          className="rounded-md p-2 hover:bg-subtle"
          aria-expanded={open}
          aria-controls="mobile-nav"
          onClick={() => setOpen((v) => !v)}
        >
          {open ? <X className="h-5 w-5" aria-hidden /> : <Menu className="h-5 w-5" aria-hidden />}
          <span className="sr-only">{open ? "Close menu" : "Open menu"}</span>
        </button>
      </header>
      {open && (
        <nav id="mobile-nav" aria-label="Main" className="no-print fixed inset-x-0 top-14 z-20 border-b border-line bg-surface p-3 shadow-sm lg:hidden">
          <NavLinks onNavigate={() => setOpen(false)} />
          <div className="mt-3 border-t border-line pt-3 text-sm text-muted">
            <p className="truncate px-2.5 pb-2">{email}</p>
            {signOut}
          </div>
        </nav>
      )}

      <aside className="no-print hidden w-60 shrink-0 border-r border-line bg-surface lg:flex lg:flex-col">
        <div className="sticky top-0 flex h-screen flex-col p-4">
          <Link href="/today" className="mb-6 px-2.5 text-lg font-semibold">JobPilot</Link>
          <nav aria-label="Main" className="flex-1">
            <NavLinks />
          </nav>
          <div className="border-t border-line pt-3 text-sm text-muted">
            <p className="truncate px-2.5 pb-2" title={email}>{email}</p>
            {signOut}
          </div>
        </div>
      </aside>

      <main id="main" className="min-w-0 flex-1 px-4 py-6 sm:px-6 lg:px-10 lg:py-8">
        <div className="mx-auto max-w-6xl">{children}</div>
      </main>
    </div>
  );
}
