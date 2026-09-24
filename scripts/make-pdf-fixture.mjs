// Regenerates tests/fixtures/sample-resume.pdf from the text fixture using Chromium.
// Usage: node scripts/make-pdf-fixture.mjs
import { chromium } from "@playwright/test";
import { readFileSync, writeFileSync } from "node:fs";

const text = readFileSync("tests/fixtures/sample-resume.txt", "utf8");
const escape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
const html = `<html><body style="font-family:Arial;font-size:11pt">${text.split("\n").map((l) => `<div>${escape(l) || "&nbsp;"}</div>`).join("")}</body></html>`;
const browser = await chromium.launch();
const page = await browser.newPage();
await page.setContent(html);
writeFileSync("tests/fixtures/sample-resume.pdf", await page.pdf({ format: "A4" }));
await browser.close();
console.log("Wrote tests/fixtures/sample-resume.pdf");
