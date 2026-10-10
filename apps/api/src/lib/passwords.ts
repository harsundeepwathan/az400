// scrypt hashes compatible with go/internal/passwords: scrypt$N$r$p$salt$key (base64).
import { randomBytes, scrypt as scryptCb, timingSafeEqual } from 'node:crypto';

function scrypt(pw: string, salt: Buffer, len: number, N: number, r: number, p: number): Promise<Buffer> {
  return new Promise((resolve, reject) =>
    scryptCb(pw, salt, len, { N, r, p, maxmem: 128 * N * r * 2 }, (err, key) => (err ? reject(err) : resolve(key))),
  );
}

export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const key = await scrypt(pw, salt, 32, 16384, 8, 1);
  return `scrypt$16384$8$1$${salt.toString('base64')}$${key.toString('base64')}`;
}

export async function verifyPassword(pw: string, encoded: string | null): Promise<boolean> {
  const parts = (encoded ?? '').split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') {
    // Burn comparable time so unknown users are not distinguishable by latency.
    await scrypt(pw, randomBytes(16), 32, 16384, 8, 1);
    return false;
  }
  const [N, r, p] = [Number(parts[1]), Number(parts[2]), Number(parts[3])];
  const want = Buffer.from(parts[5]!, 'base64');
  const got = await scrypt(pw, Buffer.from(parts[4]!, 'base64'), want.length, N, r, p);
  return got.length === want.length && timingSafeEqual(got, want);
}
