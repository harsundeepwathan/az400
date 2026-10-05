// Pure receipt logic: validation, filtering, summaries and CSV export.
// No DOM or storage access here, so everything is unit-testable in Node.

export const CATEGORIES = [
  'Groceries',
  'Dining',
  'Transport',
  'Travel',
  'Utilities',
  'Shopping',
  'Health',
  'Entertainment',
  'Office',
  'Other',
];

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

export function newId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return `r_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
}

// Amounts are stored as integer cents to avoid floating point drift.
export function parseAmountToCents(input) {
  if (typeof input === 'number') {
    return Number.isFinite(input) ? Math.round(input * 100) : NaN;
  }
  const cleaned = String(input ?? '').replace(/[^0-9.\-]/g, '');
  if (!/^-?\d*(\.\d{0,2})?$/.test(cleaned) || cleaned === '' || cleaned === '-' || cleaned === '.') {
    return NaN;
  }
  return Math.round(parseFloat(cleaned) * 100);
}

export function formatCents(cents, currency = 'USD', locale = undefined) {
  return new Intl.NumberFormat(locale, { style: 'currency', currency }).format(cents / 100);
}

export function validateReceipt(input) {
  const errors = {};
  const merchant = String(input.merchant ?? '').trim();
  if (!merchant) errors.merchant = 'Merchant is required';
  else if (merchant.length > 120) errors.merchant = 'Merchant must be 120 characters or fewer';

  const date = String(input.date ?? '');
  if (!DATE_RE.test(date) || Number.isNaN(Date.parse(`${date}T00:00:00Z`))) {
    errors.date = 'Enter a valid date';
  }

  const amountCents = parseAmountToCents(input.amount);
  if (Number.isNaN(amountCents)) errors.amount = 'Enter an amount like 12.34';
  else if (amountCents <= 0) errors.amount = 'Amount must be greater than zero';

  const category = CATEGORIES.includes(input.category) ? input.category : 'Other';

  const ok = Object.keys(errors).length === 0;
  return {
    ok,
    errors,
    value: ok
      ? {
          merchant,
          date,
          amountCents,
          category,
          paymentMethod: String(input.paymentMethod ?? '').trim(),
          notes: String(input.notes ?? '').trim(),
          image: input.image || null,
        }
      : null,
  };
}

export function createReceipt(input, now = new Date()) {
  const result = validateReceipt(input);
  if (!result.ok) return result;
  const stamp = now.toISOString();
  return { ...result, value: { id: newId(), ...result.value, createdAt: stamp, updatedAt: stamp } };
}

export function updateReceipt(existing, input, now = new Date()) {
  const result = validateReceipt({ ...existing, amount: existing.amountCents / 100, ...input });
  if (!result.ok) return result;
  return {
    ...result,
    value: { ...existing, ...result.value, id: existing.id, createdAt: existing.createdAt, updatedAt: now.toISOString() },
  };
}

export function filterReceipts(receipts, { query = '', category = '', from = '', to = '' } = {}) {
  const q = query.trim().toLowerCase();
  return receipts.filter((r) => {
    if (category && r.category !== category) return false;
    if (from && r.date < from) return false;
    if (to && r.date > to) return false;
    if (q) {
      const haystack = `${r.merchant} ${r.notes} ${r.category} ${r.paymentMethod}`.toLowerCase();
      if (!haystack.includes(q)) return false;
    }
    return true;
  });
}

const SORTERS = {
  'date-desc': (a, b) => b.date.localeCompare(a.date) || b.createdAt.localeCompare(a.createdAt),
  'date-asc': (a, b) => a.date.localeCompare(b.date) || a.createdAt.localeCompare(b.createdAt),
  'amount-desc': (a, b) => b.amountCents - a.amountCents,
  'amount-asc': (a, b) => a.amountCents - b.amountCents,
  merchant: (a, b) => a.merchant.localeCompare(b.merchant),
};

export function sortReceipts(receipts, key = 'date-desc') {
  return [...receipts].sort(SORTERS[key] ?? SORTERS['date-desc']);
}

export function summarize(receipts) {
  const totalCents = receipts.reduce((sum, r) => sum + r.amountCents, 0);
  const byCategory = {};
  const byMonth = {};
  for (const r of receipts) {
    byCategory[r.category] = (byCategory[r.category] ?? 0) + r.amountCents;
    const month = r.date.slice(0, 7);
    byMonth[month] = (byMonth[month] ?? 0) + r.amountCents;
  }
  const categories = Object.entries(byCategory)
    .map(([category, cents]) => ({ category, cents }))
    .sort((a, b) => b.cents - a.cents);
  const months = Object.entries(byMonth)
    .map(([month, cents]) => ({ month, cents }))
    .sort((a, b) => a.month.localeCompare(b.month));
  return {
    count: receipts.length,
    totalCents,
    averageCents: receipts.length ? Math.round(totalCents / receipts.length) : 0,
    categories,
    months,
  };
}

// Returns the last `n` calendar months (YYYY-MM) ending at `now`, oldest first.
export function lastMonths(n, now = new Date()) {
  const out = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
    out.push(d.toISOString().slice(0, 7));
  }
  return out;
}

function csvCell(value) {
  const s = String(value ?? '');
  // Prefix formula-like values so spreadsheets don't execute them.
  const safe = /^[=+\-@\t\r]/.test(s) ? `'${s}` : s;
  return /[",\n\r]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}

export function toCSV(receipts) {
  const header = ['Date', 'Merchant', 'Category', 'Amount', 'Payment Method', 'Notes'];
  const rows = receipts.map((r) => [
    r.date,
    r.merchant,
    r.category,
    (r.amountCents / 100).toFixed(2),
    r.paymentMethod,
    r.notes,
  ]);
  return [header, ...rows].map((row) => row.map(csvCell).join(',')).join('\r\n');
}

// Accepts data from a JSON backup; drops anything that doesn't validate.
export function importReceipts(data) {
  const list = Array.isArray(data) ? data : Array.isArray(data?.receipts) ? data.receipts : [];
  const imported = [];
  let skipped = 0;
  for (const raw of list) {
    const amount = raw?.amountCents != null ? raw.amountCents / 100 : raw?.amount;
    const result = validateReceipt({ ...raw, amount });
    if (!result.ok) {
      skipped++;
      continue;
    }
    const stamp = new Date().toISOString();
    imported.push({
      id: typeof raw.id === 'string' && raw.id ? raw.id : newId(),
      ...result.value,
      createdAt: raw.createdAt || stamp,
      updatedAt: raw.updatedAt || stamp,
    });
  }
  return { imported, skipped };
}
