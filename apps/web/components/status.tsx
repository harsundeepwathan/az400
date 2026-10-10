'use client';
import { AlertOctagon, AlertTriangle, CheckCircle2, CircleDashed, CircleHelp, PauseCircle, PowerOff, Wrench, XOctagon } from 'lucide-react';
import { cx } from './ui';
import { STATE_LABEL, PROVIDER_LABEL, PROVIDER_SLOT, type OpState } from '@/lib/state';

// Status color never carries meaning alone: every badge has an icon and a label.
const STYLE: Record<OpState, { cls: string; Icon: typeof CheckCircle2 }> = {
  healthy: { cls: 'bg-good-soft text-good-ink', Icon: CheckCircle2 },
  warning: { cls: 'bg-warning-soft text-warning-ink', Icon: AlertTriangle },
  critical: { cls: 'bg-critical-soft text-critical-ink', Icon: AlertOctagon },
  down: { cls: 'bg-critical text-white', Icon: XOctagon },
  stopped: { cls: 'bg-neutral-soft text-ink-2', Icon: PowerOff },
  unknown: { cls: 'bg-neutral-soft text-ink-2', Icon: CircleHelp },
  maintenance: { cls: 'bg-maint-soft text-maint', Icon: Wrench },
  no_data: { cls: 'bg-neutral-soft text-ink-3', Icon: CircleDashed },
};

export function StateBadge({ state, size = 'md', title }: { state: string; size?: 'sm' | 'md' | 'lg'; title?: string }) {
  const s = STYLE[state as OpState] ?? STYLE.unknown;
  const Icon = s.Icon;
  return (
    <span title={title} className={cx('inline-flex items-center gap-1 rounded-full font-medium whitespace-nowrap', s.cls,
      size === 'sm' && 'h-5 px-1.5 text-[11px]', size === 'md' && 'h-6 px-2 text-xs', size === 'lg' && 'h-8 px-3 text-sm')}>
      <Icon aria-hidden className={size === 'lg' ? 'size-4' : 'size-3.5'} />
      {STATE_LABEL[state as OpState] ?? state}
    </span>
  );
}

export function SeverityBadge({ severity }: { severity: string }) {
  return severity === 'critical'
    ? <span className="inline-flex h-5 items-center gap-1 rounded px-1.5 text-[11px] font-semibold uppercase tracking-wide bg-critical-soft text-critical-ink"><AlertOctagon className="size-3" aria-hidden />Critical</span>
    : <span className="inline-flex h-5 items-center gap-1 rounded px-1.5 text-[11px] font-semibold uppercase tracking-wide bg-warning-soft text-warning-ink"><AlertTriangle className="size-3" aria-hidden />Warning</span>;
}

export function IncidentStatus({ status }: { status: string }) {
  const map: Record<string, string> = {
    open: 'border-critical/40 text-critical-ink', acknowledged: 'border-border-strong text-ink-2', resolved: 'border-good/40 text-good-ink',
  };
  const Icon = status === 'resolved' ? CheckCircle2 : status === 'acknowledged' ? PauseCircle : AlertOctagon;
  return (
    <span className={cx('inline-flex h-5 items-center gap-1 rounded border px-1.5 text-[11px] font-medium capitalize', map[status])}>
      <Icon className="size-3" aria-hidden />{status}
    </span>
  );
}

export function ProviderTag({ provider, className }: { provider: string; className?: string }) {
  const slot = PROVIDER_SLOT[provider] ?? 8;
  return (
    <span className={cx('inline-flex items-center gap-1.5 whitespace-nowrap text-ink-2', className)}>
      <span aria-hidden className="inline-block size-2 rounded-[2px]" style={{ background: `var(--series-${slot})` }} />
      {PROVIDER_LABEL[provider] ?? provider}
    </span>
  );
}

/** Horizontal meter for a utilization percentage, colored by threshold band. */
export function Meter({ value, warn = 80, crit = 90, label }: { value: number | null | undefined; warn?: number; crit?: number; label?: string }) {
  if (value == null) return <span className="text-ink-3">—</span>;
  const v = Math.max(0, Math.min(100, value));
  const color = v >= crit ? 'var(--critical)' : v >= warn ? 'var(--warning)' : 'var(--ink-3)';
  return (
    <span className="inline-flex w-full min-w-[72px] items-center gap-1.5" title={label}>
      <span className="relative h-1.5 flex-1 overflow-hidden rounded-full bg-surface-3">
        <span className="absolute inset-y-0 left-0 rounded-full" style={{ width: `${v}%`, background: color }} />
      </span>
      <span className={cx('tabular w-9 text-right text-xs', v >= crit ? 'font-semibold text-critical-ink' : v >= warn ? 'text-warning-ink' : 'text-ink-2')}>{v.toFixed(0)}%</span>
    </span>
  );
}
