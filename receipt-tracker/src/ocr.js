// On-device OCR using Tesseract.js (WebAssembly). The library and the English
// language model (~4 MB) are fetched from the CDN on the first scan, then
// cached by the browser, so later scans are fast and images never leave the device.

const TESSERACT_URL = 'https://cdn.jsdelivr.net/npm/tesseract.js@7.0.0/dist/tesseract.min.js';

let workerPromise = null;
let progressHandler = () => {};

function loadScript(src) {
  return new Promise((resolve, reject) => {
    if (globalThis.Tesseract) return resolve();
    const s = document.createElement('script');
    s.src = src;
    s.crossOrigin = 'anonymous';
    s.onload = () => resolve();
    s.onerror = () => reject(new Error('Could not load the OCR engine. Check your connection.'));
    document.head.append(s);
  });
}

function getWorker() {
  workerPromise ??= (async () => {
    await loadScript(TESSERACT_URL);
    return globalThis.Tesseract.createWorker('eng', 1, {
      logger: (m) => progressHandler(m),
    });
  })().catch((err) => {
    workerPromise = null; // allow a retry after a network failure
    throw err;
  });
  return workerPromise;
}

// Starts downloading the engine in the background so the first scan feels quicker.
export function warmUpOcr() {
  getWorker().catch(() => {});
}

// Grayscale + contrast stretch + sensible size: noticeably better OCR on phone photos.
export function preprocess(img, maxSide = 2000) {
  const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(img.width * scale);
  canvas.height = Math.round(img.height * scale);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
  const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
  const px = data.data;
  let min = 255, max = 0;
  for (let i = 0; i < px.length; i += 4) {
    const g = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
    px[i] = g;
    if (g < min) min = g;
    if (g > max) max = g;
  }
  const range = Math.max(1, max - min);
  for (let i = 0; i < px.length; i += 4) {
    const v = ((px[i] - min) / range) * 255;
    px[i] = px[i + 1] = px[i + 2] = v;
  }
  ctx.putImageData(data, 0, 0);
  return canvas;
}

/**
 * Reads text from an image. onProgress receives { stage, progress (0-1) }.
 */
export async function recognize(img, onProgress = () => {}) {
  progressHandler = (m) => {
    if (m.status === 'recognizing text') onProgress({ stage: 'Reading receipt…', progress: m.progress });
    else onProgress({ stage: 'Preparing scanner (first time only)…', progress: m.progress ?? 0 });
  };
  onProgress({ stage: 'Preparing scanner…', progress: 0 });
  let worker;
  try {
    worker = await getWorker();
  } catch {
    throw new Error("Couldn't load the scanner — check your internet connection (needed once for the first scan).");
  }
  const { data } = await worker.recognize(preprocess(img));
  return data.text ?? '';
}
