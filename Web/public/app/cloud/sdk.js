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
          db: sdk.firestore.getFirestore(app),
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
