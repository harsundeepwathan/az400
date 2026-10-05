import {
  CATEGORIES,
  createReceipt,
  updateReceipt,
  filterReceipts,
  sortReceipts,
  summarize,
  lastMonths,
  formatCents,
  toCSV,
  importReceipts,
} from './receipts.js';
import { openStore } from './storage.js';
import { sampleReceipts } from './sample.js';

const $ = (sel) => document.querySelector(sel);
const fmt = (cents) => formatCents(cents);

const state = {
  store: null,
  receipts: [],
  editingId: null,
  pendingImage: null, // data URL, null = none, undefined = unchanged
};

// ---------- Rendering ----------

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'style') node.style.cssText = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) if (c != null) node.append(c);
  return node;
}

function currentFilters() {
  return {
    query: $('#fQuery').value,
    category: $('#fCategory').value,
    from: $('#fFrom').value,
    to: $('#fTo').value,
  };
}

function render() {
  const filters = currentFilters();
  const visible = sortReceipts(filterReceipts(state.receipts, filters), $('#fSort').value);
  const summary = summarize(visible);
  const isFiltered = Object.values(filters).some(Boolean);

  // Stats reflect the filtered view so search doubles as a quick report.
  $('#statTotal').textContent = fmt(summary.totalCents);
  $('#statCount').textContent = String(summary.count);
  $('#statAvg').textContent = fmt(summary.averageCents);
  const thisMonth = localMonth(new Date());
  $('#statMonth').textContent = fmt(summary.months.find((m) => m.month === thisMonth)?.cents ?? 0);

  const note = $('#filterNote');
  note.hidden = !isFiltered;
  note.textContent = `Showing ${visible.length} of ${state.receipts.length} receipts`;

  renderMonthChart(summary);
  renderCategoryChart(summary);
  renderList(visible);
}

function localMonth(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

function renderMonthChart(summary) {
  const now = new Date();
  const months = lastMonths(6, new Date(Date.UTC(now.getFullYear(), now.getMonth(), 1)));
  const map = Object.fromEntries(summary.months.map((m) => [m.month, m.cents]));
  const max = Math.max(1, ...months.map((m) => map[m] ?? 0));
  const current = localMonth(now);
  $('#monthChart').replaceChildren(
    ...months.map((m) => {
      const cents = map[m] ?? 0;
      const label = new Date(`${m}-01T00:00:00`).toLocaleString(undefined, { month: 'short' });
      return el('div', { class: `bar${m === current ? ' current' : ''}`, title: `${m}: ${fmt(cents)}` },
        el('span', { class: 'bar-amount' }, cents ? compact(cents) : '–'),
        el('div', { class: 'bar-track' }, el('div', { class: 'bar-fill', style: `height:${(cents / max) * 100}%` })),
        el('span', {}, label));
    }),
  );
}

function compact(cents) {
  return new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD', notation: 'compact', maximumFractionDigits: 1 }).format(cents / 100);
}

function renderCategoryChart(summary) {
  const list = $('#categoryChart');
  if (!summary.categories.length) {
    list.replaceChildren(el('li', { class: 'muted' }, 'No spending to show yet.'));
    return;
  }
  const max = summary.categories[0].cents;
  list.replaceChildren(
    ...summary.categories.slice(0, 6).map(({ category, cents }) => {
      const pct = summary.totalCents ? Math.round((cents / summary.totalCents) * 100) : 0;
      return el('li', { class: 'cat-row' },
        el('span', {}, category, el('span', { class: 'muted' }, ` · ${pct}%`)),
        el('span', { class: 'amt' }, fmt(cents)),
        el('div', { class: 'cat-track' }, el('div', { class: 'cat-fill', style: `width:${(cents / max) * 100}%` })));
    }),
  );
}

function renderList(visible) {
  $('#emptyState').hidden = state.receipts.length > 0;
  const list = $('#receiptList');
  if (state.receipts.length && !visible.length) {
    list.replaceChildren(el('li', { class: 'empty' }, 'No receipts match these filters.'));
    return;
  }
  list.replaceChildren(
    ...visible.map((r) => {
      const thumb = r.image
        ? el('button', { class: 'thumb', type: 'button', 'aria-label': `View photo for ${r.merchant}`, onclick: (e) => { e.stopPropagation(); showImage(r.image); } },
            el('img', { class: 'thumb', src: r.image, alt: '' }))
        : el('span', { class: 'thumb placeholder', 'aria-hidden': 'true' }, r.merchant.slice(0, 1).toUpperCase());
      const date = new Date(`${r.date}T00:00:00`).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
      return el('li', {
          class: 'receipt', tabindex: '0', role: 'button', 'aria-label': `Edit ${r.merchant}, ${fmt(r.amountCents)}`,
          onclick: () => openForm(r),
          onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openForm(r); } },
        },
        thumb,
        el('div', { class: 'r-main' },
          el('div', { class: 'r-merchant' }, r.merchant),
          el('div', { class: 'r-meta' },
            el('span', {}, date),
            el('span', { class: 'chip' }, r.category),
            r.paymentMethod ? el('span', {}, r.paymentMethod) : null,
            r.notes ? el('span', { title: r.notes }, r.notes.length > 40 ? `${r.notes.slice(0, 40)}…` : r.notes) : null)),
        el('div', { class: 'r-amount' }, fmt(r.amountCents)));
    }),
  );
}

// ---------- Form ----------

const form = $('#receiptForm');
const dialog = $('#receiptDialog');

function todayLocal() {
  const d = new Date();
  return `${localMonth(d)}-${String(d.getDate()).padStart(2, '0')}`;
}

function openForm(receipt = null) {
  state.editingId = receipt?.id ?? null;
  state.pendingImage = undefined;
  form.reset();
  clearErrors();
  $('#dialogTitle').textContent = receipt ? 'Edit receipt' : 'Add receipt';
  $('#deleteBtn').hidden = !receipt;
  form.merchant.value = receipt?.merchant ?? '';
  form.date.value = receipt?.date ?? todayLocal();
  form.amount.value = receipt ? (receipt.amountCents / 100).toFixed(2) : '';
  form.category.value = receipt?.category ?? 'Groceries';
  form.paymentMethod.value = receipt?.paymentMethod ?? '';
  form.notes.value = receipt?.notes ?? '';
  setPreview(receipt?.image ?? null);
  dialog.showModal();
  form.merchant.focus();
}

function setPreview(src) {
  const img = $('#photoPreview');
  img.hidden = !src;
  if (src) img.src = src; else img.removeAttribute('src');
  $('#photoRemove').hidden = !src;
}

function clearErrors() {
  form.querySelectorAll('[data-err]').forEach((n) => { n.textContent = ''; });
  form.querySelectorAll('[aria-invalid]').forEach((n) => n.removeAttribute('aria-invalid'));
}

function showErrors(errors) {
  clearErrors();
  let first = null;
  for (const [field, msg] of Object.entries(errors)) {
    form.querySelector(`[data-err="${field}"]`).textContent = msg;
    form[field].setAttribute('aria-invalid', 'true');
    first ??= form[field];
  }
  first?.focus();
}

form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const input = {
    merchant: form.merchant.value,
    date: form.date.value,
    amount: form.amount.value,
    category: form.category.value,
    paymentMethod: form.paymentMethod.value,
    notes: form.notes.value,
  };
  if (state.pendingImage !== undefined) input.image = state.pendingImage;

  const existing = state.receipts.find((r) => r.id === state.editingId);
  const result = existing ? updateReceipt(existing, input) : createReceipt(input);
  if (!result.ok) return showErrors(result.errors);

  try {
    await state.store.put(result.value);
  } catch (err) {
    console.error(err);
    return toast('Could not save — storage may be full.');
  }
  state.receipts = existing
    ? state.receipts.map((r) => (r.id === existing.id ? result.value : r))
    : [...state.receipts, result.value];
  dialog.close();
  render();
  toast(existing ? 'Receipt updated' : 'Receipt added');
});

$('#deleteBtn').addEventListener('click', async () => {
  const r = state.receipts.find((x) => x.id === state.editingId);
  if (!r || !confirm(`Delete receipt from ${r.merchant}?`)) return;
  await state.store.remove(r.id);
  state.receipts = state.receipts.filter((x) => x.id !== r.id);
  dialog.close();
  render();
  toast('Receipt deleted');
});

$('#photoInput').addEventListener('change', async (e) => {
  const file = e.target.files?.[0];
  e.target.value = '';
  if (!file) return;
  try {
    state.pendingImage = await downscaleImage(file, 1280, 0.8);
    setPreview(state.pendingImage);
  } catch {
    toast('Could not read that image');
  }
});

$('#photoRemove').addEventListener('click', () => {
  state.pendingImage = null;
  setPreview(null);
});

// Shrinks photos before storing so a few hundred receipts stay well within quota.
function downscaleImage(file, maxSide, quality) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(img.width * scale);
      canvas.height = Math.round(img.height * scale);
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      URL.revokeObjectURL(url);
      resolve(canvas.toDataURL('image/jpeg', quality));
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('bad image')); };
    img.src = url;
  });
}

function showImage(src) {
  $('#imageFull').src = src;
  $('#imageDialog').showModal();
}

document.querySelectorAll('[data-close]').forEach((btn) =>
  btn.addEventListener('click', () => btn.closest('dialog').close()));
// Click on the backdrop closes dialogs.
document.querySelectorAll('dialog').forEach((d) =>
  d.addEventListener('click', (e) => { if (e.target === d) d.close(); }));

// ---------- Toolbar actions ----------

function download(name, content, type) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const a = el('a', { href: url, download: name });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function closeMenu() { $('.menu').open = false; }

$('#addBtn').addEventListener('click', () => openForm());

function exportCsv() {
  closeMenu();
  const visible = sortReceipts(filterReceipts(state.receipts, currentFilters()), $('#fSort').value);
  if (!visible.length) return toast('Nothing to export');
  download(`receipts-${todayLocal()}.csv`, toCSV(visible), 'text/csv');
}
$('#exportCsv').addEventListener('click', exportCsv);
$('#exportCsvMenu').addEventListener('click', exportCsv);

$('#exportJson').addEventListener('click', () => {
  closeMenu();
  download(`receipts-backup-${todayLocal()}.json`, JSON.stringify({ version: 1, receipts: state.receipts }, null, 2), 'application/json');
});

$('#importJson').addEventListener('change', async (e) => {
  closeMenu();
  const file = e.target.files?.[0];
  e.target.value = '';
  if (!file) return;
  try {
    const { imported, skipped } = importReceipts(JSON.parse(await file.text()));
    await state.store.putMany(imported);
    const byId = new Map(state.receipts.map((r) => [r.id, r]));
    imported.forEach((r) => byId.set(r.id, r));
    state.receipts = [...byId.values()];
    render();
    toast(`Restored ${imported.length} receipt${imported.length === 1 ? '' : 's'}${skipped ? `, skipped ${skipped} invalid` : ''}`);
  } catch (err) {
    console.error(err);
    toast('That file is not a valid backup');
  }
});

$('#loadSample').addEventListener('click', async () => {
  closeMenu();
  const { imported } = importReceipts(sampleReceipts());
  await state.store.putMany(imported);
  state.receipts = [...state.receipts, ...imported];
  render();
  toast(`Added ${imported.length} sample receipts`);
});

$('#clearAll').addEventListener('click', async () => {
  closeMenu();
  if (!state.receipts.length || !confirm(`Delete all ${state.receipts.length} receipts? This cannot be undone.`)) return;
  await state.store.clear();
  state.receipts = [];
  render();
  toast('All receipts deleted');
});

let toastTimer;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2600);
}

// ---------- Init ----------

async function init() {
  const options = CATEGORIES.map((c) => el('option', { value: c }, c));
  $('#fCategory').append(...options.map((o) => o.cloneNode(true)));
  $('#formCategory').append(...options);

  const filters = $('#filters');
  filters.addEventListener('input', render);
  filters.addEventListener('reset', () => setTimeout(render));
  filters.addEventListener('submit', (e) => e.preventDefault());

  document.addEventListener('keydown', (e) => {
    if (e.key === 'n' && !e.metaKey && !e.ctrlKey && !document.querySelector('dialog[open]') &&
        !['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName)) {
      e.preventDefault();
      openForm();
    }
  });

  state.store = await openStore();
  state.receipts = await state.store.getAll();
  if (!state.store.persistent) toast('Storage unavailable — receipts will not be saved after you close this tab');
  render();
}

init();
