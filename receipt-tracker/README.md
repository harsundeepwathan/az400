# Receipt Tracker

A lightweight, dependency-free web app for capturing and reviewing receipts. Everything runs in the browser and data stays on your device (IndexedDB).

## Features

- **Scan and log immediately**: tap **Scan receipt** to take a photo with your phone, or choose, drag in or paste an image on a computer. The app reads the receipt on your device and logs it right away, then shows **Edit** and **Undo** options. See [Receipt scanning](#receipt-scanning) below.
- **Capture receipts**: merchant, date, amount, category, payment method, notes, and an optional photo (on phones it can open the camera). Photos are downscaled to keep storage small.
- **Edit and delete**: click any receipt to open it.
- **Search and filter** by text, category and date range, and sort by date, amount or merchant.
- **Dashboard**: total, count, average and this-month spend, a 6-month bar chart, and a category breakdown. The stats follow your current filters, so a search doubles as a quick report.
- **Export** the filtered list to CSV, which is protected against spreadsheet formula injection.
- **Back up and restore** all receipts as JSON.
- Sample data, light/dark themes, a mobile layout, and keyboard shortcuts (`s` scans, `n` adds a receipt manually).

## Receipt scanning

1. The photo is cleaned up (grayscale, contrast, resized) and read with [Tesseract.js](https://github.com/naptha/tesseract.js) OCR, which runs in the browser via WebAssembly. Images never leave the device.
2. `src/parse.js` pulls the **merchant** (first meaningful line), **total** (prefers `GRAND TOTAL` / `AMOUNT DUE` / `TOTAL` and ignores subtotal, tax, tips and change), **date** (several US, ISO, day-first and month-name formats; future dates are ignored), **payment method** (card brand and last 4 digits) and a **category** from keywords.
3. If the merchant and a labelled total were both read clearly, the receipt is **logged immediately**. If the date couldn't be read it is set to today, and the confirmation says so.
4. Otherwise the review form opens pre-filled, with the photo attached and the fields it was unsure about highlighted, so nothing is logged with a guessed amount.
5. Scanning the same receipt twice (same merchant, date and amount) is flagged as a possible duplicate.

The OCR engine and English language data (a few MB) are downloaded from jsDelivr on the first scan and then cached, so the first scan needs a connection and takes longer.

## Run locally

It's a static site with no build step:

```bash
cd receipt-tracker
npm start            # serves on http://localhost:8080
# or: python3 -m http.server 8080
```

ES modules need an HTTP server, so opening `index.html` directly via `file://` won't work.

## Test

```bash
npm test             # Node's built-in test runner, no install needed
```

## Structure

```
receipt-tracker/
├── index.html          # markup and dialogs
├── styles.css          # theme tokens and responsive layout
├── src/
│   ├── receipts.js     # pure logic: validation, filters, summaries, CSV, import
│   ├── parse.js        # OCR text → merchant, date, total, payment, category
│   ├── ocr.js          # Tesseract.js loader + image preprocessing
│   ├── storage.js      # IndexedDB persistence (in-memory fallback)
│   ├── sample.js       # demo data
│   └── app.js          # UI wiring
└── test/
    ├── receipts.test.js
    └── parse.test.js
```

Amounts are stored as integer cents to avoid floating-point rounding errors.

## CI/CD

`azure-pipelines.yml` at the repo root runs the tests on every push to `master` and publishes the static site as a pipeline artifact (`receipt-tracker-site`), ready for a deploy stage such as Azure Static Web Apps or Azure Storage static hosting.
