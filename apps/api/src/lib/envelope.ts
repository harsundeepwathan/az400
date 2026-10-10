// Envelope encryption compatible with go/internal/secrets (same JSON format and AAD).
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

export interface Keyring {
  activeId: string;
  keys: Map<string, Buffer>;
}

export function parseKeyring(spec: string): Keyring {
  const keys = new Map<string, Buffer>();
  let activeId = '';
  for (const part of spec.split(',').map((s) => s.trim()).filter(Boolean)) {
    const i = part.indexOf(':');
    if (i < 0) throw new Error('keyring entry must be id:base64key');
    const id = 'local:' + part.slice(0, i);
    const key = Buffer.from(part.slice(i + 1), 'base64');
    if (key.length !== 32) throw new Error(`key ${id} must be 32 bytes`);
    if (!activeId) activeId = id;
    keys.set(id, key);
  }
  if (!activeId) throw new Error('empty keyring');
  return { activeId, keys };
}

function gcmSeal(key: Buffer, plaintext: Buffer, aad: string): { nonce: Buffer; ct: Buffer } {
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, nonce);
  c.setAAD(Buffer.from(aad));
  const ct = Buffer.concat([c.update(plaintext), c.final(), c.getAuthTag()]);
  return { nonce, ct };
}

function gcmOpen(key: Buffer, nonce: Buffer, ct: Buffer, aad: string): Buffer {
  const d = createDecipheriv('aes-256-gcm', key, nonce);
  d.setAAD(Buffer.from(aad));
  d.setAuthTag(ct.subarray(ct.length - 16));
  return Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
}

export function seal(kr: Keyring, plaintext: string, aad: string): Buffer {
  const kek = kr.keys.get(kr.activeId)!;
  const dek = randomBytes(32);
  const w = gcmSeal(kek, dek, 'skywatch-dek');
  const d = gcmSeal(dek, Buffer.from(plaintext, 'utf8'), aad);
  return Buffer.from(
    JSON.stringify({
      v: 1,
      kid: kr.activeId,
      wk: Buffer.concat([w.nonce, w.ct]).toString('base64'),
      n: d.nonce.toString('base64'),
      ct: d.ct.toString('base64'),
    }),
  );
}

export function open(kr: Keyring, blob: Buffer, aad: string): string {
  const e = JSON.parse(blob.toString('utf8')) as { v: number; kid: string; wk: string; n: string; ct: string };
  if (e.v !== 1) throw new Error('unsupported envelope');
  const kek = kr.keys.get(e.kid);
  if (!kek) throw new Error('unknown key');
  const wk = Buffer.from(e.wk, 'base64');
  const dek = gcmOpen(kek, wk.subarray(0, 12), wk.subarray(12), 'skywatch-dek');
  return gcmOpen(dek, Buffer.from(e.n, 'base64'), Buffer.from(e.ct, 'base64'), aad).toString('utf8');
}

export const cloudAccountAad = (orgId: string, accountId: string) => `cloud_account:${orgId}:${accountId}`;
export const channelAad = (orgId: string, channelId: string) => `notification_channel:${orgId}:${channelId}`;
