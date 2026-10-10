// Thin client for the management API. All requests go to the same origin (/api is
// proxied); state-changing requests carry the session's CSRF token.
let csrfToken = '';
export const setCsrf = (t: string) => { csrfToken = t; };

export class ApiError extends Error {
  constructor(public status: number, message: string, public code?: string, public issues?: { path: string; message: string }[]) {
    super(message);
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = {};
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (method !== 'GET') headers['x-csrf-token'] = csrfToken;
  const res = await fetch(`/api/v1${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'same-origin' });
  if (res.status === 401 && typeof window !== 'undefined' && !path.startsWith('/auth') && !window.location.pathname.startsWith('/login')) {
    window.location.href = '/login?next=' + encodeURIComponent(window.location.pathname + window.location.search);
  }
  const ct = res.headers.get('content-type') ?? '';
  const data = ct.includes('application/json') ? await res.json() : await res.text();
  if (!res.ok) {
    const d = data as { message?: string; error?: string; issues?: { path: string; message: string }[] };
    throw new ApiError(res.status, d?.message ?? `Request failed (${res.status})`, d?.error, d?.issues);
  }
  return data as T;
}

export const api = {
  get: <T,>(p: string) => request<T>('GET', p),
  post: <T,>(p: string, b: unknown = {}) => request<T>('POST', p, b),
  put: <T,>(p: string, b: unknown) => request<T>('PUT', p, b),
  patch: <T,>(p: string, b: unknown) => request<T>('PATCH', p, b),
  del: <T,>(p: string) => request<T>('DELETE', p),
};

export function qs(params: Record<string, string | number | undefined | null | false>) {
  const u = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '' && v !== false) u.set(k, String(v));
  const s = u.toString();
  return s ? `?${s}` : '';
}
