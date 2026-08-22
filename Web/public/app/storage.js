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
  return rememberedMode() ?? LOCAL;
}

/**
 * The remembered choice, or `null` when this visitor has never made one.
 *
 * Separate from `preferredMode()` because "chose local" and "has not chosen"
 * need different treatment at launch, and collapsing them is what made the
 * server's workspace the silent default for everyone.
 */
export function rememberedMode() {
  try {
    const stored = window.localStorage.getItem(MODE_KEY);
    return stored === CLOUD || stored === LOCAL ? stored : null;
  } catch {
    return null;
  }
}

/**
 * What the welcome screen says about each place documents can live (WR-1).
 *
 * Pure, and separate from the rendering, because the sharing warning used to
 * be written inline on the wrong branch: it appeared only while the *cloud*
 * was in use, so the one set of people it actually described — everyone using
 * the server's workspace — were the only ones never shown it.
 *
 * The warning is a property of the option, not of which option is selected, so
 * here it cannot depend on that again. It is also phrased as reachability
 * rather than as "shared", because that is the part that is true of both
 * deployments: served from a laptop it means only you, and served from a
 * public address it means anybody at all. Both follow from the same sentence.
 */
export function storageChoices({ mode: current = mode, account = currentAccount(), workspaceName } = {}) {
  const cloudActive = current === CLOUD;
  return [
    {
      id: CLOUD,
      active: cloudActive,
      recommended: !cloudActive,
      title: account && cloudActive
        ? `Cloud — ${account.email || account.name}`
        : 'Your Google account',
      detail: cloudActive
        ? 'Private to your account, and synced to every device you sign in on.'
        : 'Sign in to keep your documents to yourself and reach them on every device.',
      label: cloudActive ? 'Sign out' : 'Connect Google account',
    },
    {
      id: LOCAL,
      active: !cloudActive,
      recommended: false,
      title: workspaceName ? `On this server — ${workspaceName}` : 'On this server',
      detail: 'Anyone who can open this page can read and change these documents.',
      label: cloudActive ? 'Use local files' : null,
    },
  ];
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
 *
 * A visitor who has never chosen is asked the same question of Firebase before
 * the server's workspace is used at all. Someone already signed in to Google
 * on this site has documents of their own, and starting them in a workspace
 * every other visitor can edit is the wrong guess to make silently. The server
 * is the fallback for being signed out, not the default. `chosen` says which
 * of the two happened, so the welcome screen can lead with the question rather
 * than present a decision that looks already made.
 */
export async function restoreStorage() {
  const remembered = rememberedMode();

  if (remembered === null) {
    try {
      const account = await restoreAccount();
      if (account) {
        await activateCloud(account.uid);
        publish();
        return { mode: CLOUD, account, reason: null, chosen: false };
      }
    } catch {
      /* A first visit must never fail to start; fall through to the server. */
    }
    useLocal({ remember: false });
    return { mode: LOCAL, account: null, reason: null, chosen: false };
  }

  if (remembered !== CLOUD) {
    useLocal({ remember: false });
    return { mode: LOCAL, account: null, reason: null, chosen: true };
  }
  try {
    const account = await restoreAccount();
    if (!account) {
      useLocal({ remember: false });
      return { mode: LOCAL, account: null, reason: 'signed-out', chosen: true };
    }
    await activateCloud(account.uid);
    publish();
    return { mode: CLOUD, account, reason: null, chosen: true };
  } catch (error) {
    useLocal({ remember: false });
    return { mode: LOCAL, account: null, reason: error?.message ?? 'unavailable', chosen: true };
  }
}

export { currentAccount, signIn };

/** True when the active backend can serve a document at all. */
export function storageIsReady() {
  return mode === LOCAL || currentAccount() !== null;
}

export { api };
