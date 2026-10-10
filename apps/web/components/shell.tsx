'use client';
import { useQuery } from '@tanstack/react-query';
import {
  Activity, Bell, BellRing, Boxes, Cloud, Cpu, FileText, Gauge, HeartPulse, LayoutDashboard, ListChecks, LogOut, Monitor,
  Moon, Radar, Settings, Sun, Wrench,
} from 'lucide-react';
import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { useEffect, useState, type ReactNode } from 'react';
import { api } from '@/lib/api';
import { useMe, useSwitchOrg } from './session';
import { cx } from './ui';

const NAV: { section: string; items: { href: string; label: string; icon: typeof Activity; perm?: string }[] }[] = [
  { section: 'Monitor', items: [
    { href: '/', label: 'Overview', icon: LayoutDashboard },
    { href: '/inventory', label: 'Inventory', icon: Boxes },
    { href: '/incidents', label: 'Incidents', icon: BellRing },
    { href: '/synthetic', label: 'Synthetic checks', icon: Radar },
    { href: '/events', label: 'Change events', icon: Activity },
  ] },
  { section: 'Configure', items: [
    { href: '/alerts', label: 'Alert rules', icon: ListChecks },
    { href: '/maintenance', label: 'Maintenance', icon: Wrench },
    { href: '/accounts', label: 'Cloud accounts', icon: Cloud },
    { href: '/agents', label: 'Agents', icon: Cpu },
    { href: '/notifications', label: 'Notifications', icon: Bell },
  ] },
  { section: 'Insight', items: [
    { href: '/reports', label: 'Reports', icon: FileText },
    { href: '/platform', label: 'Monitoring health', icon: HeartPulse },
    { href: '/settings', label: 'Settings', icon: Settings },
  ] },
];

function ThemeToggle() {
  const [theme, setTheme] = useState<string>('light');
  useEffect(() => setTheme(document.documentElement.dataset.theme ?? 'light'), []);
  const flip = () => {
    const t = theme === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = t;
    try { localStorage.setItem('sw-theme', t); } catch { /* storage unavailable */ }
    setTheme(t);
  };
  return (
    <button onClick={flip} aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`} className="rounded-md p-1.5 text-ink-2 hover:bg-surface-2 hover:text-ink">
      {theme === 'dark' ? <Sun className="size-4" /> : <Moon className="size-4" />}
    </button>
  );
}

export function AppShell({ children }: { children: ReactNode }) {
  const me = useMe();
  const path = usePathname();
  const router = useRouter();
  const switchOrg = useSwitchOrg();
  const summary = useQuery({
    queryKey: ['nav-incidents'],
    queryFn: () => api.get<{ incidents: { unacknowledged: number } }>('/dashboard/summary'),
    refetchInterval: 30_000,
    enabled: !!me.active_org,
  });
  const unack = summary.data?.incidents.unacknowledged ?? 0;

  async function logout() {
    await api.post('/auth/logout');
    router.replace('/login');
  }

  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 hidden h-screen w-56 shrink-0 flex-col border-r border-border bg-surface md:flex">
        <div className="flex h-12 items-center gap-2 px-4">
          <Radar className="size-5 text-accent" aria-hidden />
          <span className="text-[15px] font-semibold tracking-tight">Skywatch</span>
        </div>
        <nav className="scroll-thin flex-1 overflow-y-auto px-2 pb-4" aria-label="Main">
          {NAV.map((s) => (
            <div key={s.section} className="mt-4">
              <div className="px-2 pb-1 text-[10px] font-semibold uppercase tracking-wider text-ink-3">{s.section}</div>
              {s.items.map((i) => {
                const active = i.href === '/' ? path === '/' : path.startsWith(i.href);
                return (
                  <Link key={i.href} href={i.href} aria-current={active ? 'page' : undefined}
                    className={cx('flex h-8 items-center gap-2.5 rounded-md px-2 text-[13px]', active ? 'bg-accent-soft font-medium text-ink' : 'text-ink-2 hover:bg-surface-2 hover:text-ink')}>
                    <i.icon className={cx('size-4', active ? 'text-accent' : 'text-ink-3')} aria-hidden />
                    <span className="flex-1">{i.label}</span>
                    {i.href === '/incidents' && unack > 0 && (
                      <span className="tabular rounded-full bg-critical px-1.5 text-[11px] font-semibold text-white" aria-label={`${unack} unacknowledged`}>{unack}</span>
                    )}
                  </Link>
                );
              })}
            </div>
          ))}
        </nav>
        <div className="border-t border-border p-2">
          <Link href="/wallboard" className="flex h-8 items-center gap-2.5 rounded-md px-2 text-[13px] text-ink-2 hover:bg-surface-2 hover:text-ink">
            <Monitor className="size-4 text-ink-3" aria-hidden />NOC wallboard
          </Link>
        </div>
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-20 flex h-12 items-center gap-3 border-b border-border bg-surface/95 px-4 backdrop-blur">
          <label className="sr-only" htmlFor="org">Organization</label>
          <select id="org" value={me.active_org?.id ?? ''} onChange={(e) => switchOrg(e.target.value).then(() => router.push('/'))}
            className="h-8 max-w-[260px] rounded-md border border-border-strong bg-surface px-2 text-[13px] font-medium">
            {!me.active_org && <option value="">Select organization</option>}
            {me.organizations.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
          </select>
          {me.role && <span className="hidden rounded border border-border px-1.5 py-0.5 text-[11px] text-ink-3 sm:inline">{me.role.replace('_', ' ')}</span>}
          <div className="flex-1" />
          <Link href="/incidents" className="md:hidden"><Gauge className="size-4" /></Link>
          <ThemeToggle />
          <span className="hidden text-xs text-ink-2 sm:inline">{me.user.display_name}</span>
          <button onClick={logout} aria-label="Sign out" className="rounded-md p-1.5 text-ink-2 hover:bg-surface-2 hover:text-ink"><LogOut className="size-4" /></button>
        </header>
        {me.active_org?.is_demo && (
          <div role="status" className="border-b border-warning/40 bg-warning-soft px-4 py-1.5 text-xs text-warning-ink">
            <strong>Demo environment — synthetic data.</strong> Resources, metrics and incidents in this organization are generated for demonstration and do not reflect real infrastructure.
          </div>
        )}
        <main className="min-w-0 flex-1 p-4 md:p-6">{children}</main>
      </div>
    </div>
  );
}

export function PageHeader({ title, subtitle, actions }: { title: string; subtitle?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-lg font-semibold tracking-tight">{title}</h1>
        {subtitle && <p className="mt-0.5 text-xs text-ink-3">{subtitle}</p>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </div>
  );
}

