import { describe, expect, it } from 'vitest';
import { computeAvailability } from '../src/lib/availability.js';
import { toCsv } from '../src/lib/csv.js';
import { open, parseKeyring, seal } from '../src/lib/envelope.js';
import { hashPassword, verifyPassword } from '../src/lib/passwords.js';
import { validateTarget } from '../src/lib/targets.js';
import { slope } from '../src/routes/reports.js';
import { KEKS } from './helpers.js';

describe('availability', () => {
  const from = new Date('2026-10-01T00:00:00Z');
  const h = (n: number) => new Date(from.getTime() + n * 3600e3);
  const ivs = [
    { state: 'no_data', start: h(0), end: h(1) },
    { state: 'healthy', start: h(1), end: h(5) },
    { state: 'down', start: h(5), end: h(6) },
    { state: 'maintenance', start: h(6), end: h(7) },
    { state: 'critical', start: h(7), end: h(8) },
    { state: 'healthy', start: h(8), end: null },
  ];
  it('matches the Go implementation and documented policy', () => {
    const a = computeAvailability(ivs, from, h(10));
    expect(a.available_seconds).toBe(7 * 3600);
    expect(a.unavailable_seconds).toBe(3600);
    expect(a.excluded_seconds).toBe(2 * 3600);
    expect(a.percent).toBe(87.5);
    expect(computeAvailability(ivs, from, h(10), { criticalIsDown: true }).percent).toBe(75);
  });
  it('never reports a percentage without observations', () => {
    expect(computeAvailability([], from, h(10)).percent).toBeNull();
  });
});

describe('envelope', () => {
  const kr = parseKeyring(KEKS);
  it('round-trips and binds AAD', () => {
    const blob = seal(kr, '{"token":"x"}', 'cloud_account:a:b');
    expect(open(kr, blob, 'cloud_account:a:b')).toBe('{"token":"x"}');
    expect(() => open(kr, blob, 'cloud_account:other:b')).toThrow();
    expect(blob.toString()).not.toContain('token');
  });
});

describe('passwords', () => {
  it('hashes and verifies in the shared scrypt format', async () => {
    const h = await hashPassword('s3cret!');
    expect(h.startsWith('scrypt$16384$8$1$')).toBe(true);
    expect(await verifyPassword('s3cret!', h)).toBe(true);
    expect(await verifyPassword('nope', h)).toBe(false);
    expect(await verifyPassword('x', null)).toBe(false);
  });
});

describe('csv', () => {
  it('neutralises spreadsheet formulas and quotes', () => {
    expect(toCsv(['a'], [['=HYPERLINK("x")'], ['a,b']])).toBe('a\r\n"\'=HYPERLINK(""x"")"\r\n"a,b"\r\n');
  });
});

describe('targets', () => {
  it('blocks private targets for public probes', () => {
    for (const t of ['http://127.0.0.1/', 'http://10.0.0.5/', 'http://169.254.169.254/latest', 'http://localhost/', 'http://[::1]/', 'http://db.internal/'])
      expect(() => validateTarget('http', t, 'public')).toThrow();
    expect(() => validateTarget('http', 'https://example.com/health', 'public')).not.toThrow();
    expect(() => validateTarget('tcp', '10.0.0.5:5432', 'private')).not.toThrow();
    expect(() => validateTarget('tcp', 'example.com', 'public')).toThrow(/port/);
    expect(() => validateTarget('http', 'ftp://example.com', 'public')).toThrow();
  });
});

describe('forecast slope', () => {
  it('computes per-hour growth', () => {
    expect(slope([[0, 50], [1, 51], [2, 52]])).toBeCloseTo(1);
    expect(slope([[0, 1]])).toBeNull();
  });
});

describe('cross-language envelope', () => {
  it('opens the vector also asserted by go/internal/secrets', () => {
    const v = '{"v":1,"kid":"local:v1","wk":"ZBPPlqVOdNYF3mc3o2+xgjjnXv+hhIwX/Q/yLUDb3IVQgnK5nw9Vtgy24DGQRx4bXJG8S2c8nQcDCahG","n":"ioBmisasapVK0Yvo","ct":"3kmVX7iTbSIP+0/5cAR7UNS35Q6xH+5uOpUdsqgMMLtt1wXGOwHxHJFu"}';
    expect(open(parseKeyring(KEKS), Buffer.from(v), 'cloud_account:org:acct')).toBe('{"token":"dop_v1_example"}');
  });
});
