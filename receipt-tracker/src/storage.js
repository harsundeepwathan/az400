// IndexedDB persistence. Receipt photos can be large, so IndexedDB is used
// instead of localStorage (which caps out around 5 MB in most browsers).
// Falls back to an in-memory store if IndexedDB is unavailable (e.g. some
// private browsing modes) so the app still works for the session.

const DB_NAME = 'receipt-tracker';
const STORE = 'receipts';
const VERSION = 1;

function openDb() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: 'id' });
        store.createIndex('date', 'date');
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function tx(db, mode, fn) {
  return new Promise((resolve, reject) => {
    const t = db.transaction(STORE, mode);
    const store = t.objectStore(STORE);
    const result = fn(store);
    t.oncomplete = () => resolve(result?.result ?? result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  });
}

function memoryStore() {
  const map = new Map();
  return {
    persistent: false,
    async getAll() { return [...map.values()]; },
    async put(r) { map.set(r.id, r); },
    async putMany(list) { list.forEach((r) => map.set(r.id, r)); },
    async remove(id) { map.delete(id); },
    async clear() { map.clear(); },
  };
}

export async function openStore() {
  try {
    if (typeof indexedDB === 'undefined') throw new Error('IndexedDB unavailable');
    const db = await openDb();
    return {
      persistent: true,
      getAll: () => tx(db, 'readonly', (s) => s.getAll()),
      put: (r) => tx(db, 'readwrite', (s) => { s.put(r); }),
      putMany: (list) => tx(db, 'readwrite', (s) => { list.forEach((r) => s.put(r)); }),
      remove: (id) => tx(db, 'readwrite', (s) => { s.delete(id); }),
      clear: () => tx(db, 'readwrite', (s) => { s.clear(); }),
    };
  } catch (err) {
    console.warn('Falling back to in-memory storage:', err);
    return memoryStore();
  }
}
