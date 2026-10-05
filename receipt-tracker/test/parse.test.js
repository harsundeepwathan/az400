import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseReceiptText, parseMoney, findDate, findMerchant, findPaymentMethod } from '../src/parse.js';

const today = new Date(2026, 9, 5);

const grocery = `
WHOLE FOODS MARKET
1440 P STREET NW
WASHINGTON, DC 20005
(202) 555-0123
ORGANIC BANANAS        2.49
ALMOND MILK            4.99
SOURDOUGH LOAF         6.50
SUBTOTAL              13.98
TAX                    0.84
TOTAL                 14.82
VISA ************4821
CHANGE                 0.00
10/03/2026 14:22
THANK YOU FOR SHOPPING
`;

test('parses a typical grocery receipt', () => {
  const r = parseReceiptText(grocery, today);
  assert.equal(r.merchant, 'Whole Foods Market');
  assert.equal(r.amountCents, 1482);
  assert.equal(r.date, '2026-10-03');
  assert.equal(r.category, 'Groceries');
  assert.equal(r.paymentMethod, 'Visa ••4821');
  assert.equal(r.autoLog, true);
});

test('prefers grand total / amount due over subtotal and tax', () => {
  const r = parseReceiptText(`Joe's Pizzeria\nSubtotal $40.00\nTax $3.20\nTip $8.00\nGrand Total $51.20\nCash $60.00\nChange $8.80`, today);
  assert.equal(r.amountCents, 5120);
  assert.equal(r.category, 'Dining');
  assert.equal(r.paymentMethod, 'Cash');
});

test('handles OCR quirks: comma decimals, TOTA1, amount on next line', () => {
  assert.equal(parseReceiptText('SHELL\nTOTA1  54,10', today).amountCents, 5410);
  assert.equal(parseReceiptText('SHELL\nTOTAL\n$ 54.10', today).amountCents, 5410);
});

test('falls back to the largest amount without auto-logging', () => {
  const r = parseReceiptText('CORNER SHOP\nMilk 2.00\nBread 3.50\nCash 10.00', today);
  assert.equal(r.amountCents, 350);
  assert.equal(r.confidence.amount, false);
  assert.equal(r.autoLog, false);
});

test('returns safe defaults for unreadable text', () => {
  const r = parseReceiptText('~~ ## ..', today);
  assert.equal(r.amountCents, null);
  assert.equal(r.merchant, '');
  assert.equal(r.date, '2026-10-05');
  assert.equal(r.autoLog, false);
});

test('parseMoney reads several formats', () => {
  assert.deepEqual(parseMoney('$1,234.56 and 7.00 and 12,34'), [123456, 700, 1234]);
});

test('findDate supports common formats and rejects future dates', () => {
  assert.equal(findDate('2026-09-14', today).date, '2026-09-14');
  assert.equal(findDate('9/14/26', today).date, '2026-09-14');
  assert.equal(findDate('25/09/2026', today).date, '2026-09-25');
  assert.equal(findDate('Sep 14, 2026', today).date, '2026-09-14');
  assert.equal(findDate('14 September 2026', today).date, '2026-09-14');
  assert.equal(findDate('EXP 12/30/2027', today).confident, false);
});

test('findMerchant skips noise, addresses and phone lines', () => {
  assert.equal(findMerchant(['*** RECEIPT ***', '123 Main St', 'Blue Bottle Coffee', 'Latte 5.00']), 'Blue Bottle Coffee');
});

test('findPaymentMethod detects card brands', () => {
  assert.equal(findPaymentMethod('MASTERCARD XXXX1234'), 'Mastercard ••1234');
  assert.equal(findPaymentMethod('AMEX'), 'Amex');
  assert.equal(findPaymentMethod('nothing here'), '');
});

test('tolerates OCR noise seen on real photos', () => {
  const noisy = `BLUE BOTTLE COFFEE\n66 mint Street\nost Latte 5.75\nsuBTOTAL 13.50\n™ 1.36\nTora 16.86\nMASTERCARD +#=+++++7731\noor2a/2026 08:41 A`;
  const r = parseReceiptText(noisy, today);
  assert.equal(r.amountCents, 1686);
  assert.equal(r.paymentMethod, 'Mastercard ••7731');
  assert.equal(r.confidence.date, false);
  assert.equal(r.autoLog, true);
});
