'use client';
import clsx from 'clsx';
import { forwardRef, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes, type TextareaHTMLAttributes } from 'react';

export const cx = clsx;

type Variant = 'primary' | 'secondary' | 'ghost' | 'danger';
export const Button = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: 'sm' | 'md' }>(
  function Button({ variant = 'secondary', size = 'md', className, ...p }, ref) {
    return (
      <button
        ref={ref}
        {...p}
        className={cx(
          'inline-flex items-center justify-center gap-1.5 rounded-md font-medium whitespace-nowrap transition-colors disabled:opacity-50 disabled:cursor-not-allowed',
          size === 'sm' ? 'h-7 px-2.5 text-xs' : 'h-8 px-3 text-[13px]',
          variant === 'primary' && 'bg-accent text-accent-ink hover:brightness-110',
          variant === 'secondary' && 'bg-surface border border-border-strong text-ink hover:bg-surface-2',
          variant === 'ghost' && 'text-ink-2 hover:bg-surface-2 hover:text-ink',
          variant === 'danger' && 'bg-critical text-white hover:brightness-110',
          className,
        )}
      />
    );
  },
);

export function Card({ title, actions, children, className, bodyClassName, subtitle }: {
  title?: ReactNode; subtitle?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string; bodyClassName?: string;
}) {
  return (
    <section className={cx('rounded-lg border border-border bg-surface shadow-[var(--shadow)]', className)}>
      {(title || actions) && (
        <header className="flex items-center justify-between gap-3 border-b border-border px-4 py-2.5">
          <div className="min-w-0">
            <h2 className="truncate text-[13px] font-semibold text-ink">{title}</h2>
            {subtitle && <p className="truncate text-xs text-ink-3">{subtitle}</p>}
          </div>
          {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
        </header>
      )}
      <div className={cx('p-4', bodyClassName)}>{children}</div>
    </section>
  );
}

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function Input({ className, ...p }, ref) {
  const width = /(^|\s)w-/.test(className ?? '') ? '' : 'w-full';
  return <input ref={ref} {...p} className={cx('h-8 rounded-md border border-border-strong bg-surface px-2.5 text-[13px] text-ink placeholder:text-ink-3', width, className)} />;
});

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(function Textarea({ className, ...p }, ref) {
  return <textarea ref={ref} {...p} className={cx('w-full rounded-md border border-border-strong bg-surface px-2.5 py-2 text-[13px] text-ink placeholder:text-ink-3', className)} />;
});

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(function Select({ className, ...p }, ref) {
  return <select ref={ref} {...p} className={cx('h-8 rounded-md border border-border-strong bg-surface px-2 text-[13px] text-ink', className)} />;
});

export function Field({ label, hint, error, children }: { label: string; hint?: ReactNode; error?: string; children: ReactNode }) {
  return (
    <label className="block space-y-1">
      <span className="text-xs font-medium text-ink-2">{label}</span>
      {children}
      {hint && !error && <span className="block text-xs text-ink-3">{hint}</span>}
      {error && <span className="block text-xs text-critical-ink">{error}</span>}
    </label>
  );
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={cx('animate-pulse rounded-md bg-surface-3/70', className)} />;
}

export function Empty({ title, children, icon }: { title: string; children?: ReactNode; icon?: ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center gap-1.5 px-6 py-10 text-center">
      {icon && <div className="text-ink-3">{icon}</div>}
      <div className="text-[13px] font-medium text-ink">{title}</div>
      {children && <div className="max-w-md text-xs text-ink-3">{children}</div>}
    </div>
  );
}

export function ErrorNote({ error }: { error: unknown }) {
  if (!error) return null;
  const e = error as { message?: string; issues?: { path: string; message: string }[] };
  return (
    <div role="alert" className="rounded-md border border-critical/30 bg-critical-soft px-3 py-2 text-xs text-critical-ink">
      {e.message ?? 'Something went wrong'}
      {e.issues && <ul className="mt-1 list-disc pl-4">{e.issues.map((i) => <li key={i.path + i.message}>{i.path ? `${i.path}: ` : ''}{i.message}</li>)}</ul>}
    </div>
  );
}

export function Tabs<T extends string>({ value, onChange, items }: { value: T; onChange: (v: T) => void; items: { value: T; label: ReactNode }[] }) {
  return (
    <div role="tablist" className="inline-flex rounded-md border border-border bg-surface-2 p-0.5">
      {items.map((i) => (
        <button key={i.value} role="tab" aria-selected={value === i.value} onClick={() => onChange(i.value)}
          className={cx('h-6 rounded px-2.5 text-xs font-medium', value === i.value ? 'bg-surface text-ink shadow-[var(--shadow)]' : 'text-ink-2 hover:text-ink')}>
          {i.label}
        </button>
      ))}
    </div>
  );
}

export function Table({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cx('scroll-thin overflow-x-auto', className)}>
      <table className="w-full border-collapse text-left text-[13px]">{children}</table>
    </div>
  );
}
export const Th = ({ children, className, ...p }: { children?: ReactNode; className?: string } & React.ThHTMLAttributes<HTMLTableCellElement>) => (
  <th {...p} className={cx('sticky top-0 z-[1] border-b border-border bg-surface px-3 py-2 text-[11px] font-medium uppercase tracking-wide text-ink-3', className)}>{children}</th>
);
export const Td = ({ children, className, ...p }: { children?: ReactNode; className?: string } & React.TdHTMLAttributes<HTMLTableCellElement>) => (
  <td {...p} className={cx('border-b border-border px-3 py-2 align-middle', className)}>{children}</td>
);

export function Dialog({ open, onClose, title, children, width = 'max-w-lg' }: { open: boolean; onClose: () => void; title: string; children: ReactNode; width?: string }) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 pt-[10vh]" onMouseDown={(e) => e.target === e.currentTarget && onClose()}
      onKeyDown={(e) => e.key === 'Escape' && onClose()}>
      <div role="dialog" aria-modal="true" aria-label={title} className={cx('w-full rounded-lg border border-border bg-surface shadow-xl', width)}>
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h2 className="text-sm font-semibold">{title}</h2>
          <button aria-label="Close" onClick={onClose} className="rounded p-1 text-ink-3 hover:bg-surface-2 hover:text-ink">✕</button>
        </header>
        <div className="p-4">{children}</div>
      </div>
    </div>
  );
}

export function KV({ items }: { items: [ReactNode, ReactNode][] }) {
  return (
    <dl className="grid grid-cols-[minmax(110px,auto)_1fr] gap-x-4 gap-y-1.5 text-[13px]">
      {items.map(([k, v], i) => (
        <div key={i} className="contents">
          <dt className="text-ink-3">{k}</dt>
          <dd className="min-w-0 break-words text-ink">{v ?? '—'}</dd>
        </div>
      ))}
    </dl>
  );
}

export function Mono({ children, className }: { children: ReactNode; className?: string }) {
  return <span className={cx('font-mono text-[12px]', className)}>{children}</span>;
}
