// Validation of user-supplied network targets (synthetic checks, webhooks). This is an
// early, user-friendly check; the authoritative SSRF control is enforced at connect
// time by the Go probe/notifier (go/internal/netguard), which also defeats DNS
// rebinding.
import { isIP } from 'node:net';
import { badRequest } from './errors.js';

const privateV4 = [
  [0x00000000, 8], [0x0a000000, 8], [0x64400000, 10], [0x7f000000, 8], [0xa9fe0000, 16], [0xac100000, 12],
  [0xc0000000, 24], [0xc0a80000, 16], [0xc6120000, 15], [0xe0000000, 4], [0xf0000000, 4],
] as const;

function v4ToInt(ip: string) {
  return ip.split('.').reduce((a, o) => (a << 8) + Number(o), 0) >>> 0;
}

export function isPrivateAddress(ip: string): boolean {
  if (isIP(ip) === 4) {
    const n = v4ToInt(ip);
    return privateV4.some(([base, bits]) => n >>> (32 - bits) === base >>> (32 - bits));
  }
  if (isIP(ip) === 6) {
    const l = ip.toLowerCase();
    return l === '::' || l === '::1' || l.startsWith('fc') || l.startsWith('fd') || l.startsWith('fe8') ||
      l.startsWith('fe9') || l.startsWith('fea') || l.startsWith('feb') || l.startsWith('::ffff:') || l.startsWith('ff');
  }
  return false;
}

const blockedHostnames = new Set(['localhost', 'metadata.google.internal', 'metadata', 'instance-data']);

/** Validates a target for a public probe. Private probes may target private ranges. */
export function validateTarget(kind: string, target: string, scope: 'public' | 'private') {
  let host = target;
  if (kind === 'http') {
    let u: URL;
    try {
      u = new URL(target);
    } catch {
      throw badRequest('Target must be a valid http(s) URL');
    }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') throw badRequest('Only http and https URLs are supported');
    if (u.username || u.password) throw badRequest('Credentials in URLs are not allowed');
    host = u.hostname.replace(/^\[|\]$/g, '');
  } else if (kind === 'tcp' || kind === 'tls') {
    const m = /^(\[[^\]]+\]|[^:]+)(?::(\d{1,5}))?$/.exec(target);
    if (!m) throw badRequest('Target must be host or host:port');
    host = m[1]!.replace(/^\[|\]$/g, '');
    if (kind === 'tcp' && !m[2]) throw badRequest('TCP targets need a port (host:port)');
  }
  if (!/^[a-zA-Z0-9.\-:]+$/.test(host)) throw badRequest('Invalid hostname');
  if (scope === 'public' && (blockedHostnames.has(host.toLowerCase()) || host.endsWith('.internal') || host.endsWith('.local') || isPrivateAddress(host))) {
    throw badRequest(
      'Public probes cannot reach private, loopback, link-local or metadata addresses. Deploy a private probe in that network instead.',
    );
  }
}

export function validateWebhookUrl(url: string) {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    throw badRequest('Invalid URL');
  }
  if (u.protocol !== 'https:') throw badRequest('Webhook URLs must use https');
  const host = u.hostname.replace(/^\[|\]$/g, '');
  if (blockedHostnames.has(host) || isPrivateAddress(host)) throw badRequest('Webhook URL points to a private address');
}
