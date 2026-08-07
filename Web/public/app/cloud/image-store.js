// The device half of the image cache: an IndexedDB object store of image bytes.
//
// IndexedDB rather than the Cache Storage API, which looks like the closer fit.
// Cache Storage keyed by URL would only help a request the browser makes on its
// own, and it does not consult it for `<img src>` without a service worker in
// front of every request. A service worker is a much larger commitment — its
// own scope, update lifecycle, and deployment story — for something this build
// needs in exactly one place. IndexedDB hands back the bytes and the caller
// decides what to do with them.

const DATABASE = 'markdown-editor-images';
const STORE = 'bytes';
const VERSION = 1;

function request(work) {
  return new Promise((resolve, reject) => {
    const pending = work();
    pending.onsuccess = () => resolve(pending.result);
    pending.onerror = () => reject(pending.error);
  });
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    const opening = indexedDB.open(DATABASE, VERSION);
    opening.onupgradeneeded = () => {
      const database = opening.result;
      if (!database.objectStoreNames.contains(STORE)) {
        database.createObjectStore(STORE, { keyPath: 'url' });
      }
    };
    opening.onsuccess = () => resolve(opening.result);
    opening.onerror = () => reject(opening.error);
    opening.onblocked = () => reject(new Error('the image cache is open in another tab'));
  });
}

/**
 * @returns {import('./image-cache.js').ImageByteStore}
 */
export function createIndexedDBImageStore() {
  /** Opened once, lazily: a store nobody reads should not cost a database. */
  let database = null;
  async function connection() {
    if (!database) database = await openDatabase();
    return database;
  }

  async function transact(mode, work) {
    const db = await connection();
    const transaction = db.transaction(STORE, mode);
    const result = await work(transaction.objectStore(STORE));
    await new Promise((resolve, reject) => {
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
    return result;
  }

  return {
    async get(url) {
      const row = await transact('readonly', (store) => request(() => store.get(url)));
      return row ? row.bytes : null;
    },

    async put(url, bytes) {
      await transact('readwrite', (store) =>
        request(() => store.put({ url, bytes, stored: Date.now() })));
    },

    async forget(urls) {
      await transact('readwrite', async (store) => {
        for (const url of urls) await request(() => store.delete(url));
      });
    },
  };
}

/** True when this browser can hold image bytes at all. */
export function canCacheImages() {
  return typeof indexedDB !== 'undefined';
}
