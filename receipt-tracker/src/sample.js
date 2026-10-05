// Demo data spread over the last few months, relative to today.
const SAMPLES = [
  [0, 3, 'Whole Foods Market', 8642, 'Groceries', 'Debit card', 'Weekly shop'],
  [0, 5, 'Blue Bottle Coffee', 1275, 'Dining', 'Mobile pay', ''],
  [0, 8, 'Shell', 5410, 'Transport', 'Credit card', 'Fuel'],
  [1, 2, 'City Power & Light', 11230, 'Utilities', 'Credit card', 'Electric bill'],
  [1, 9, 'Trader Joe\'s', 6418, 'Groceries', 'Debit card', ''],
  [1, 14, 'Staples', 3299, 'Office', 'Credit card', 'Printer paper, pens'],
  [1, 21, 'Sakura Sushi', 7850, 'Dining', 'Credit card', 'Team lunch — reimbursable'],
  [2, 4, 'CVS Pharmacy', 2389, 'Health', 'Cash', ''],
  [2, 12, 'Delta Air Lines', 38900, 'Travel', 'Credit card', 'Conference flight'],
  [2, 18, 'Whole Foods Market', 9311, 'Groceries', 'Debit card', ''],
  [3, 6, 'AMC Theatres', 3150, 'Entertainment', 'Credit card', 'Movie night'],
  [3, 15, 'Uber', 2245, 'Transport', 'Mobile pay', 'Airport ride'],
  [4, 10, 'IKEA', 15499, 'Shopping', 'Credit card', 'Bookshelf'],
  [5, 7, 'City Power & Light', 9875, 'Utilities', 'Credit card', 'Electric bill'],
];

export function sampleReceipts(now = new Date()) {
  return SAMPLES.map(([monthsAgo, day, merchant, amountCents, category, paymentMethod, notes]) => {
    const d = new Date(now.getFullYear(), now.getMonth() - monthsAgo, 1);
    const lastDay = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
    // Don't create receipts dated in the future for the current month.
    const maxDay = monthsAgo === 0 ? Math.max(1, now.getDate()) : lastDay;
    d.setDate(Math.min(day, maxDay));
    const date = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    return { merchant, amountCents, category, paymentMethod, notes, date };
  });
}
