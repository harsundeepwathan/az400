'use client';
import { useRouter } from 'next/navigation';
import { useEffect, type ReactNode } from 'react';
import { SessionProvider, useMeQuery } from '@/components/session';
import { AppShell } from '@/components/shell';
import { Skeleton } from '@/components/ui';

export default function AppLayout({ children }: { children: ReactNode }) {
  const me = useMeQuery();
  const router = useRouter();
  useEffect(() => {
    if (me.isError) router.replace('/login?next=' + encodeURIComponent(window.location.pathname));
  }, [me.isError, router]);
  if (!me.data) {
    return <div className="p-6"><Skeleton className="h-8 w-64" /><Skeleton className="mt-4 h-48 w-full" /></div>;
  }
  return (
    <SessionProvider me={me.data}>
      <AppShell>{me.data.active_org ? children : <NoOrg />}</AppShell>
    </SessionProvider>
  );
}

function NoOrg() {
  return <div className="text-sm text-ink-2">You are not a member of any organization yet. Ask an administrator to invite you.</div>;
}
