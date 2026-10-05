import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseAmountToCents,
  validateReceipt,
  createReceipt,
  updateReceipt,
  filterReceipts,
  sortReceipts,
  summarize,
  lastMonths,
  toCSV,
  importReceipts,
} from '../src/receipts.js';
import { sampleReceipts } from '../src/sample.js';

const base = { merchant: 'Cafe', date: '2026-09-14', amount: '12.50', category: 'Dining' };

test('parseAmountToCents handles common inputs', () => {
  assert.equal(parseAmountToCents('12.34'), 1234);
  assert.equal(parseAmountToCents('$1,234.5'), 123450);
  assert.equal(parseAmountToCents(0.1 + 0.2), 30);
  assert.ok(Number.isNaN(parseAmountToCents('abc')));
  assert.ok(Number.isNaN(parseAmountToCents('1.234')));
  assert.ok(Number.isNaN(parseAmountToCents('')));
});

test('validateReceipt reports field errors', () => {
  const r = validateReceipt({ merchant: '  ', date: '2026-13-40', amount: '0' });
  assert.equal(r.ok, false);
  assert.deepEqual(Object.keys(r.errors).sort(), ['amount', 'date', 'merchant']);
});

test('validateReceipt normalizes values and defaults unknown category', () => {
  const r = validateReceipt({ ...base, merchant: '  Cafe  ', category: 'Nope' });
  assert.equal(r.ok, true);
  assert.equal(r.value.merchant, 'Cafe');
  assert.equal(r.value.amountCents, 1250);
  assert.equal(r.value.category, 'Other');
});

test('createReceipt and updateReceipt keep identity and timestamps', () => {
  const t0 = new Date('2026-09-14T10:00:00Z');
  const t1 = new Date('2026-09-15T10:00:00Z');
  const { value: created } = createReceipt(base, t0);
  assert.ok(created.id);
  assert.equal(created.createdAt, t0.toISOString());

  const { ok, value: updated } = updateReceipt(created, { amount: '20' }, t1);
  assert.equal(ok, true);
  assert.equal(updated.id, created.id);
  assert.equal(updated.amountCents, 2000);
  assert.equal(updated.merchant, 'Cafe');
  assert.equal(updated.createdAt, t0.toISOString());
  assert.equal(updated.updatedAt, t1.toISOString());
});

const fixtures = [
  { id: '1', merchant: 'Whole Foods', date: '2026-08-02', amountCents: 5000, category: 'Groceries', notes: '', paymentMethod: 'Visa', createdAt: 'a' },
  { id: '2', merchant: 'Shell', date: '2026-09-10', amountCents: 4000, category: 'Transport', notes: 'fuel', paymentMethod: '', createdAt: 'b' },
  { id: '3', merchant: 'Trader Joes', date: '2026-09-20', amountCents: 2500, category: 'Groceries', notes: '', paymentMethod: '', createdAt: 'c' },
];

test('filterReceipts by query, category and date range', () => {
  assert.deepEqual(filterReceipts(fixtures, { query: 'FUEL' }).map((r) => r.id), ['2']);
  assert.deepEqual(filterReceipts(fixtures, { category: 'Groceries' }).map((r) => r.id), ['1', '3']);
  assert.deepEqual(filterReceipts(fixtures, { from: '2026-09-01', to: '2026-09-15' }).map((r) => r.id), ['2']);
  assert.equal(filterReceipts(fixtures, {}).length, 3);
});

test('sortReceipts supports each mode', () => {
  assert.deepEqual(sortReceipts(fixtures, 'date-desc').map((r) => r.id), ['3', '2', '1']);
  assert.deepEqual(sortReceipts(fixtures, 'amount-asc').map((r) => r.id), ['3', '2', '1']);
  assert.deepEqual(sortReceipts(fixtures, 'merchant').map((r) => r.id), ['2', '3', '1']);
});

test('summarize totals by category and month', () => {
  const s = summarize(fixtures);
  assert.equal(s.totalCents, 11500);
  assert.equal(s.count, 3);
  assert.equal(s.averageCents, 3833);
  assert.deepEqual(s.categories[0], { category: 'Groceries', cents: 7500 });
  assert.deepEqual(s.months, [{ month: '2026-08', cents: 5000 }, { month: '2026-09', cents: 6500 }]);
  assert.equal(summarize([]).averageCents, 0);
});

test('lastMonths crosses year boundaries', () => {
  assert.deepEqual(lastMonths(3, new Date('2026-02-15T00:00:00Z')), ['2025-12', '2026-01', '2026-02']);
});

test('toCSV escapes quotes, commas and formula injection', () => {
  const csv = toCSV([{ ...fixtures[0], merchant: 'A, "B"', notes: '=SUM(A1)' }]);
  const [header, row] = csv.split('\r\n');
  assert.equal(header, 'Date,Merchant,Category,Amount,Payment Method,Notes');
  assert.equal(row, `2026-08-02,"A, ""B""",Groceries,50.00,Visa,'=SUM(A1)`);
});

test('importReceipts round-trips a backup and skips invalid rows', () => {
  const { imported, skipped } = importReceipts({ receipts: [...fixtures, { merchant: '', date: 'x' }] });
  assert.equal(imported.length, 3);
  assert.equal(skipped, 1);
  assert.equal(imported[0].id, '1');
  assert.equal(imported[0].amountCents, 5000);
});

test('sample data is valid and never dated in the future', () => {
  const now = new Date(2026, 9, 2);
  const { imported, skipped } = importReceipts(sampleReceipts(now));
  assert.equal(skipped, 0);
  assert.ok(imported.length > 10);
  assert.ok(imported.every((r) => r.date <= '2026-10-02'));
});
