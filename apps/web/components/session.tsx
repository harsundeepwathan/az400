'use client';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { createContext, useContext, useEffect, type ReactNode } from 'react';
import { api, setCsrf } from '@/lib/api';

export interface Me {
  user: { id: string; email: string; display_name: string };
  csrf_token: string;
  organizations: { id: string; name: string; slug: string; is_demo: boolean; role: string }[];
  active_org: { id: string; name: string; slug: string; is_demo: boolean } | null;
  role: string | null;
  permissions: string[];
}

const Ctx = createContext<Me | null>(null);

export function useMeQuery() {
  return useQuery({ queryKey: ['me'], queryFn: () => api.get<Me>('/me'), staleTime: 60_000, retry: false });
}

export function SessionProvider({ me, children }: { me: Me; children: ReactNode }) {
  useEffect(() => setCsrf(me.csrf_token), [me.csrf_token]);
  setCsrf(me.csrf_token);
  return <Ctx.Provider value={me}>{children}</Ctx.Provider>;
}

export function useMe(): Me {
  const me = useContext(Ctx);
  if (!me) throw new Error('useMe outside SessionProvider');
  return me;
}

export function useCan(perm: string) {
  return useMe().permissions.includes(perm);
}

export function useSwitchOrg() {
  const qc = useQueryClient();
  return async (orgId: string) => {
    const me = await api.post<Me>('/me/org', { org_id: orgId });
    setCsrf(me.csrf_token);
    qc.clear();
    qc.setQueryData(['me'], me);
  };
}
