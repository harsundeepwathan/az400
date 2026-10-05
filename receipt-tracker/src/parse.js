// Turns raw OCR text from a receipt into receipt fields.
// Pure and heuristic: it never throws, and reports which fields it is sure of
// so the UI can decide whether to log immediately or ask for a review.

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

// Money like 12.34, $1,234.56, 12,34 (OCR often swaps . and ,), optional trailing minus.
const MONEY_RE = /(?:[$€£]|usd)?\s*(-?\d{1,3}(?:[,\s]\d{3})*|-?\d+)\s?[.,]\s?(\d{2})(?!\d)/gi;

const TOTAL_PRIORITY = [
  /\b(grand\s*total|total\s*due|amount\s*due|balance\s*due|total\s*amount|amount\s*paid|total\s*paid)\b/i,
  /\btota[l1i]\b/i,
  // Common OCR misreads of TOTAL: T0TAL, TOTAI, TOT AL, Tora, TotaI…
  /^\s*t[o0]\s?[tr]\s?[a@4]\s?[l1i|]?\b/i,
];
const NOT_TOTAL = /\b(sub\s*-?\s*tota[l1]|tax|savings?|saved|discount|tip|items?\s*sold|total\s*items|change|cash\s*back|points?)\b/i;

const CATEGORY_KEYWORDS = [
  ['Groceries', /\b(grocer|market|foods?|supermarket|safeway|kroger|aldi|lidl|trader\s*joe|whole\s*foods|costco|publix|wegmans|tesco|sainsbury|produce)\b/i],
  ['Dining', /\b(cafe|caf[eé]|coffee|starbucks|restaurant|bistro|grill|pizza|pizzeria|burger|sushi|kitchen|diner|bakery|bar|pub|tavern|taco|mcdonald|subway|chipotle|server|table\s*#?\d|gratuity)\b/i],
  ['Transport', /\b(shell|chevron|exxon|mobil|bp|texaco|fuel|gasoline|unleaded|diesel|gallons?|litres?|parking|uber|lyft|taxi|transit|metro)\b/i],
  ['Travel', /\b(hotel|inn|motel|airlines?|airways|airport|resort|hilton|marriott|hyatt|airbnb|boarding)\b/i],
  ['Health', /\b(pharmacy|cvs|walgreens|rite\s*aid|clinic|medical|dental|rx|drug)\b/i],
  ['Utilities', /\b(electric|utility|utilities|water\s*bill|internet|telecom|wireless|energy)\b/i],
  ['Office', /\b(staples|office\s*depot|officemax|printing|stationery)\b/i],
  ['Entertainment', /\b(cinema|theatre|theater|amc|regal|tickets?|concert|museum|bowling)\b/i],
  ['Shopping', /\b(target|walmart|ikea|best\s*buy|amazon|apparel|clothing|department\s*store|home\s*depot|lowe'?s)\b/i],
];

const MERCHANT_SKIP = /\b(receipt|invoice|welcome|thank|store\s*#|st#|tel|phone|www\.|\.com|http|cashier|register|order\s*#|transaction|date|time|guest|server|table)\b/i;
const ADDRESS_LIKE = /^\d+\s+\w+|\b(st|street|ave|avenue|rd|road|blvd|suite|ste|hwy|dr|drive|ln|lane)\b\.?(\s|$)|\b[A-Z]{2}\s+\d{5}\b/i;

export function parseMoney(text) {
  const out = [];
  for (const m of String(text).matchAll(MONEY_RE)) {
    const whole = m[1].replace(/[,\s]/g, '');
    const cents = Math.round(parseFloat(`${whole}.${m[2]}`) * 100);
    if (Number.isFinite(cents)) out.push(cents);
  }
  return out;
}

function cleanLines(text) {
  return String(text ?? '')
    .split(/\r?\n/)
    .map((l) => l.replace(/[|_~`^]+/g, ' ').replace(/\s+/g, ' ').trim())
    .filter(Boolean);
}

export function findTotal(lines) {
  for (const re of TOTAL_PRIORITY) {
    const candidates = [];
    lines.forEach((line, i) => {
      if (!re.test(line) || NOT_TOTAL.test(line)) return;
      // The amount is usually on the same line, occasionally on the next one.
      let amounts = parseMoney(line);
      if (!amounts.length && lines[i + 1]) amounts = parseMoney(lines[i + 1]);
      const positive = amounts.filter((a) => a > 0);
      if (positive.length) candidates.push(positive[positive.length - 1]);
    });
    // Prefer the largest keyword match: a "TOTAL" line beats a stray "total" in a promo line.
    if (candidates.length) return { cents: Math.max(...candidates), confident: true };
  }
  // Fallback: the largest amount on the receipt, but amounts on tender/change
  // lines are excluded since cash given is often more than the total.
  const amounts = lines
    .filter((l) => !/\b(cash|tender|change|card\s*#|visa|mastercard|amex)\b/i.test(l))
    .flatMap(parseMoney)
    .filter((a) => a > 0 && a < 10_000_000);
  if (amounts.length) return { cents: Math.max(...amounts), confident: false };
  return { cents: null, confident: false };
}

function pad(n) { return String(n).padStart(2, '0'); }

function makeDate(y, m, d) {
  if (y < 100) y += 2000;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCMonth() !== m - 1) return null;
  return `${y}-${pad(m)}-${pad(d)}`;
}

export function findDate(text, today = new Date()) {
  const t = String(text);
  const todayStr = `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
  const candidates = [];

  for (const m of t.matchAll(/\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b/g)) {
    candidates.push(makeDate(+m[1], +m[2], +m[3]));
  }
  for (const m of t.matchAll(/\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})\b/g)) {
    const a = +m[1], b = +m[2], y = +m[3];
    // US order by default; switch to day-first when the first number can't be a month.
    candidates.push(a > 12 ? makeDate(y, b, a) : makeDate(y, a, b));
  }
  const monRe = '(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?';
  for (const m of t.matchAll(new RegExp(`\\b${monRe}\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4}|\\d{2})\\b`, 'gi'))) {
    candidates.push(makeDate(+m[3], MONTHS.indexOf(m[1].slice(0, 3).toLowerCase()) + 1, +m[2]));
  }
  for (const m of t.matchAll(new RegExp(`\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+${monRe},?\\s+(\\d{4}|\\d{2})\\b`, 'gi'))) {
    candidates.push(makeDate(+m[3], MONTHS.indexOf(m[2].slice(0, 3).toLowerCase()) + 1, +m[1]));
  }

  // Ignore impossible or future dates (often expiry dates or misreads).
  const valid = candidates.filter((d) => d && d <= todayStr && d >= '2000-01-01');
  return valid.length ? { date: valid[0], confident: true } : { date: todayStr, confident: false };
}

function titleCase(s) {
  if (/[a-z]/.test(s)) return s; // already mixed case, keep as printed
  return s.toLowerCase().replace(/\b([a-z])([a-z']*)/g, (_, a, b) => a.toUpperCase() + b);
}

export function findMerchant(lines) {
  for (const raw of lines.slice(0, 6)) {
    const line = raw.replace(/[^A-Za-z0-9&'.,\- ]/g, '').replace(/\s+/g, ' ').trim();
    const letters = (line.match(/[A-Za-z]/g) || []).length;
    if (letters < 3 || letters / line.length < 0.5) continue;
    if (MERCHANT_SKIP.test(line) || ADDRESS_LIKE.test(line)) continue;
    if (parseMoney(line).length) continue;
    return titleCase(line.replace(/^[.,\-\s]+|[.,\-\s]+$/g, '')).slice(0, 120);
  }
  return '';
}

export function guessCategory(merchant, text) {
  // Merchant name is the strongest signal, then the body of the receipt.
  for (const source of [merchant, text]) {
    for (const [category, re] of CATEGORY_KEYWORDS) if (re.test(source)) return category;
  }
  return 'Other';
}

export function findPaymentMethod(text) {
  const t = String(text);
  const last4 = t.match(/(?:[*xX#•+=.]{3,}[\s-]*)(\d{4})\b/)?.[1];
  const brand = t.match(/\b(visa|mastercard|master\s*card|mc|amex|american\s*express|discover|debit|apple\s*pay|google\s*pay)\b/i)?.[1];
  if (brand) {
    const names = { mc: 'Mastercard', 'master card': 'Mastercard', 'american express': 'Amex', amex: 'Amex', 'apple pay': 'Apple Pay', 'google pay': 'Google Pay' };
    const name = names[brand.toLowerCase()] ?? brand[0].toUpperCase() + brand.slice(1).toLowerCase();
    return last4 ? `${name} ••${last4}` : name;
  }
  if (/\bcash\b/i.test(t)) return 'Cash';
  return last4 ? `Card ••${last4}` : '';
}

export function parseReceiptText(text, today = new Date()) {
  const lines = cleanLines(text);
  const total = findTotal(lines);
  const date = findDate(lines.join('\n'), today);
  const merchant = findMerchant(lines);
  return {
    merchant,
    date: date.date,
    amountCents: total.cents,
    category: guessCategory(merchant, lines.join('\n')),
    paymentMethod: findPaymentMethod(lines.join('\n')),
    confidence: {
      merchant: Boolean(merchant),
      date: date.confident,
      amount: total.confident,
    },
    // Safe to log without review only when the essentials were read reliably.
    autoLog: Boolean(merchant) && total.confident && total.cents > 0,
  };
}
