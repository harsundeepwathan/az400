// Runtime configuration from environment variables. See deploy/.env.example.
function req(env: NodeJS.ProcessEnv, name: string, fallback?: string): string {
  const v = env[name] ?? fallback;
  if (v === undefined || v === '') throw new Error(`${name} is required`);
  return v;
}

export interface Config {
  databaseUrl: string;
  port: number;
  host: string;
  publicUrl: string;
  production: boolean;
  keks: string;
  controlUrl: string;
  controlToken: string;
  sessionTtlHours: number;
  localLogin: boolean;
  oidc?: { issuer: string; clientId: string; clientSecret: string; scopes: string };
  ingestPublicUrl: string;
  trustProxy: boolean;
}

export function loadConfig(env = process.env): Config {
  const production = env.NODE_ENV === 'production';
  const oidcIssuer = env.SKYWATCH_OIDC_ISSUER;
  return {
    databaseUrl: req(env, 'SKYWATCH_API_DATABASE_URL'),
    port: Number(env.PORT ?? 4000),
    host: env.HOST ?? '127.0.0.1',
    publicUrl: env.SKYWATCH_PUBLIC_URL ?? 'http://localhost:3000',
    production,
    keks: req(env, 'SKYWATCH_KEKS'),
    controlUrl: env.SKYWATCH_CONTROL_URL ?? 'http://127.0.0.1:8081',
    controlToken: env.SKYWATCH_CONTROL_TOKEN ?? '',
    sessionTtlHours: Number(env.SKYWATCH_SESSION_TTL_HOURS ?? 12),
    // Local password login exists for development and the demo environment only.
    localLogin: env.SKYWATCH_LOCAL_LOGIN === 'true' || (!production && env.SKYWATCH_LOCAL_LOGIN !== 'false'),
    oidc: oidcIssuer
      ? {
          issuer: oidcIssuer,
          clientId: req(env, 'SKYWATCH_OIDC_CLIENT_ID'),
          clientSecret: req(env, 'SKYWATCH_OIDC_CLIENT_SECRET'),
          scopes: env.SKYWATCH_OIDC_SCOPES ?? 'openid email profile',
        }
      : undefined,
    ingestPublicUrl: env.SKYWATCH_INGEST_PUBLIC_URL ?? 'https://localhost:8443',
    trustProxy: env.SKYWATCH_TRUST_PROXY === 'true',
  };
}
