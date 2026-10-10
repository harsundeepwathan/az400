'use client';
import { useQuery } from '@tanstack/react-query';
import { Radar } from 'lucide-react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Suspense, useState } from 'react';
import { Button, ErrorNote, Field, Input } from '@/components/ui';
import { api, setCsrf } from '@/lib/api';

function LoginForm() {
  const router = useRouter();
  const params = useSearchParams();
  const cfg = useQuery({ queryKey: ['auth-config'], queryFn: () => api.get<{ local_login: boolean; oidc: boolean }>('/auth/config') });
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const next = params.get('next');
  const safeNext = next && next.startsWith('/') && !next.startsWith('//') ? next : '/';

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const me = await api.post<{ csrf_token: string }>('/auth/login', { email, password });
      setCsrf(me.csrf_token);
      router.replace(safeNext);
    } catch (err) {
      setError(err);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <div className="w-full max-w-sm">
        <div className="mb-6 flex items-center gap-2">
          <Radar className="size-6 text-accent" aria-hidden />
          <span className="text-lg font-semibold tracking-tight">Skywatch</span>
        </div>
        <div className="rounded-lg border border-border bg-surface p-6 shadow-[var(--shadow)]">
          <h1 className="mb-1 text-base font-semibold">Sign in</h1>
          <p className="mb-5 text-xs text-ink-3">Multi-cloud infrastructure monitoring</p>
          {cfg.data?.oidc && (
            <a href="/api/v1/auth/oidc/start" className="mb-4 flex h-9 w-full items-center justify-center rounded-md bg-accent text-sm font-medium text-accent-ink hover:brightness-110">
              Continue with single sign-on
            </a>
          )}
          {cfg.data?.local_login && (
            <form onSubmit={submit} className="space-y-3">
              {cfg.data?.oidc && <div className="text-center text-xs text-ink-3">or use a local account</div>}
              <Field label="Email"><Input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
              <Field label="Password"><Input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
              <ErrorNote error={error} />
              <Button type="submit" variant={cfg.data?.oidc ? 'secondary' : 'primary'} className="w-full" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</Button>
            </form>
          )}
          {cfg.data && !cfg.data.local_login && !cfg.data.oidc && <ErrorNote error={{ message: 'No sign-in method is configured.' }} />}
        </div>
        <p className="mt-4 text-center text-xs text-ink-3">Multi-factor authentication is enforced by your identity provider.</p>
      </div>
    </div>
  );
}

export default function LoginPage() {
  return <Suspense><LoginForm /></Suspense>;
}
