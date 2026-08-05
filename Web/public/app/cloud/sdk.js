// Loads the Firebase SDK, and only when it is actually needed.
//
// The imports are dynamic for two reasons. Nobody who never signs in should
// pay to download an SDK they will not use — the local build is a complete
// editor on its own and stays dependency-free at runtime. And these are the
// only absolute URLs in the app: every other import is relative, which is what
// lets the deploy script version the whole module graph by putting it in a
// `v/<hash>/` directory. A CDN import is unaffected by that, which is exactly
// what we want here, and exactly why it must be pinned.

import { firebaseConfig, FIREBASE_CDN } from './config.js';
import { ApiError } from '../backends/api-error.js';

let loading = null;

async function importAll() {
  try {
    const [app, auth, firestore, storage] = await Promise.all([
      import(`${FIREBASE_CDN}/firebase-app.js`),
      import(`${FIREBASE_CDN}/firebase-auth.js`),
      import(`${FIREBASE_CDN}/firebase-firestore.js`),
      import(`${FIREBASE_CDN}/firebase-storage.js`),
    ]);
    return { app, auth, firestore, storage };
  } catch {
    throw new ApiError(
      'The editor could not load Firebase.',
      'Check your network connection, or keep working with files on this device.'
    );
  }
}

/**
 * Opens Firestore with an on-disk cache, so the cloud workspace survives
 * being offline.
 *
 * `getFirestore` gives an in-memory cache: it makes a second read in the same
 * session cheap, and it is gone the moment the tab reloads. That is the wrong
 * trade for this app. In cloud mode the server holds the only copy of the
 * user's writing, so a reload on a train, or a laptop opened somewhere with no
 * signal, would show an empty workspace. `persistentLocalCache` keeps what has
 * been read in IndexedDB and queues writes made while offline, sending them
 * when the network comes back.
 *
 * What it does *not* do is mirror the whole account. Firestore caches the
 * documents this client has actually read or written, so a document never
 * opened on this device is not available offline. That is the honest limit of
 * "local copy" here (WR-24).
 *
 * Multi-tab, because two tabs of a web editor is ordinary. Without a tab
 * manager only the first tab gets persistence and the rest silently run
 * without it.
 *
 * Persistence is genuinely unavailable in some places — private browsing in
 * parts of Safari and Firefox, and anything with IndexedDB switched off — so a
 * failure falls back to the memory cache. Offline support stops working; the
 * editor still opens, which is the right way round.
 */
export function openFirestore(firestoreModule, app) {
  const {
    initializeFirestore,
    persistentLocalCache,
    persistentMultipleTabManager,
    getFirestore,
  } = firestoreModule;
  try {
    return initializeFirestore(app, {
      localCache: persistentLocalCache({
        tabManager: persistentMultipleTabManager(),
      }),
    });
  } catch (error) {
    console.warn(
      'Firestore could not store documents on this device, so the cloud workspace will not be available offline.',
      error
    );
    return getFirestore(app);
  }
}

/**
 * Resolves to the SDK modules plus a ready `app`, `auth`, `db`, and `bucket`.
 * Cached, so signing in and then listing a folder loads it once.
 */
export function loadFirebase() {
  if (!loading) {
    loading = importAll()
      .then((sdk) => {
        const app = sdk.app.initializeApp(firebaseConfig);
        return {
          ...sdk,
          instance: app,
          authentication: sdk.auth.getAuth(app),
          db: openFirestore(sdk.firestore, app),
          bucket: sdk.storage.getStorage(app),
        };
      })
      .catch((error) => {
        // Never cache a failure: the next attempt may be after the network
        // came back, and a permanently poisoned promise would look like a
        // permanent outage.
        loading = null;
        throw error;
      });
  }
  return loading;
}

/** True once the SDK has been loaded, without triggering a load. */
export function firebaseIsLoaded() {
  return loading !== null;
}
