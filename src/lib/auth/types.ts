export type SessionUser = { id: string; email: string };
export type AuthResult = { ok: true; message?: string } | { ok: false; error: string };
