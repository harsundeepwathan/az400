# Receipt Tracker

A lightweight, dependency-free web app for capturing and reviewing receipts. Everything runs in the browser and data stays on your device (IndexedDB).

## Features

- **Capture receipts**: merchant, date, amount, category, payment method, notes, and an optional photo (on phones it can open the camera). Photos are downscaled to keep storage small.
- **Edit and delete**: click any receipt to open it.
- **Search and filter** by text, category and date range, and sort by date, amount or merchant.
- **Dashboard**: total, count, average and this-month spend, a 6-month bar chart, and a category breakdown. The stats follow your current filters, so a search doubles as a quick report.
- **Export** the filtered list to CSV, which is protected against spreadsheet formula injection.
- **Back up and restore** all receipts as JSON.
- Sample data, light/dark themes, a mobile layout, and a keyboard shortcut (`n` adds a receipt).

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
│   ├── storage.js      # IndexedDB persistence (in-memory fallback)
│   ├── sample.js       # demo data
│   └── app.js          # UI wiring
└── test/
    └── receipts.test.js
```

Amounts are stored as integer cents to avoid floating-point rounding errors.

## CI/CD

`azure-pipelines.yml` at the repo root runs the tests on every push to `master` and publishes the static site as a pipeline artifact (`receipt-tracker-site`), ready for a deploy stage such as Azure Static Web Apps or Azure Storage static hosting.
