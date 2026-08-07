// Which storage the editor is using, and how it changes.
//
// Two backends, one at a time, chosen by the user and remembered. The rule
// that makes this safe is that a path means different things in each mode:
// `Notes/Ideas.md` on the server's disk and `Notes/Ideas.md` in an account are
// unrelated documents. So anything remembered by path — the recent list, the
// saved-for-later list, the last open document — is namespaced per mode, and
// switching modes cannot make the editor open the wrong file.

import { api, setBackend } from './api.js';
import { localBackend } from './backends/local.js';
import { createFirestoreBackend } from './backends/firestore.js';
import { createFirestoreNodeStore, createFirebaseAssetStore } from './cloud/firestore-store.js';
import { createImageCache, nullImageCache } from './cloud/image-cache.js';
import { createIndexedDBImageStore, canCacheImages } from './cloud/image-store.js';
import { restoreAccount, currentAccount, signIn, signOutOfAccount } from './cloud/session.js';

const MODE_KEY = 'markdown-editor.storageMode';

export const LOCAL = 'local';
export const CLOUD = 'cloud';

const listeners = new Set();
let mode = LOCAL;

/**
 * Namespaces a per-document preference key by the storage it belongs to.
 *
 * Local keeps the unprefixed key so an existing install's recent documents
 * survive this change; only the cloud list is new.
 */
export function scopedKey(key, forMode = mode) {
  return forMode === LOCAL ? key : `${key}.${forMode}`;
}

export function storageMode() {
  return mode;
}

export function isCloud() {
  return mode === CLOUD;
}

export function observeStorage(listener) {
  listeners.add(listener);
  listener(mode, currentAccount());
  return () => listeners.delete(listener);
}

function publish() {
  for (const listener of listeners) listener(mode, currentAccount());
}

function rememberMode(next) {
  try {
    window.localStorage.setItem(MODE_KEY, next);
  } catch {
    /* private browsing; the choice just will not persist */
  }
}

export function preferredMode() {
  try {
    return window.localStorage.getItem(MODE_KEY) === CLOUD ? CLOUD : LOCAL;
  } catch {
    return LOCAL;
  }
}

async function activateCloud(uid) {
  const [nodes, assets] = await Promise.all([
    createFirestoreNodeStore(uid),
    createFirebaseAssetStore(uid),
  ]);
  // Firestore's persistent cache covers documents but not Storage objects, so
  // images need a cache of their own or an offline document renders empty
  // frames. A browser without IndexedDB simply keeps working online.
  const images = canCacheImages()
    ? createImageCache({ store: createIndexedDBImageStore() })
    : nullImageCache();
  setBackend(createFirestoreBackend({ nodes, assets, images }));
  mode = CLOUD;
}

export function useLocal({ remember = true } = {}) {
  setBackend(localBackend);
  mode = LOCAL;
  if (remember) rememberMode(LOCAL);
  publish();
}

/** Signs in if necessary, then switches to the account's documents. */
export async function useCloud() {
  const account = currentAccount() ?? (await restoreAccount()) ?? (await signIn());
  await activateCloud(account.uid);
  rememberMode(CLOUD);
  publish();
  return account;
}

export async function signOutAndUseLocal() {
  await signOutOfAccount();
  useLocal();
}

/**
 * Restores the remembered mode at launch.
 *
 * Cloud is only restored when Firebase says the session is still valid — it
 * never opens a sign-in window during boot, because a pop-up nobody asked for
 * is blocked by the browser anyway. If the session has expired the editor
 * falls back to local rather than starting on an error, and the welcome screen
 * offers to reconnect.
 */
export async function restoreStorage() {
  if (preferredMode() !== CLOUD) {
    useLocal({ remember: false });
    return { mode: LOCAL, account: null, reason: null };
  }
  try {
    const account = await restoreAccount();
    if (!account) {
      useLocal({ remember: false });
      return { mode: LOCAL, account: null, reason: 'signed-out' };
    }
    await activateCloud(account.uid);
    publish();
    return { mode: CLOUD, account, reason: null };
  } catch (error) {
    useLocal({ remember: false });
    return { mode: LOCAL, account: null, reason: error?.message ?? 'unavailable' };
  }
}

export { currentAccount, signIn };

/** True when the active backend can serve a document at all. */
export function storageIsReady() {
  return mode === LOCAL || currentAccount() !== null;
}

export { api };
