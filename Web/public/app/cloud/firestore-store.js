// The `NodeStore` and `AssetStore` the cloud backend actually runs against.
//
// Deliberately thin. Everything with a decision in it lives in
// `backends/firestore.js` and runs under test; this file is the part that
// cannot be tested without a network, so there is as little of it as possible
// and each piece maps directly onto one SDK call.
//
// Two things here are not obvious and are the reason this file exists at all
// rather than the backend calling the SDK itself.

import { loadFirebase } from './sdk.js';
import { NODES_COLLECTION, USERS_COLLECTION } from './config.js';
import * as paths from './paths.js';
import { ApiError } from '../backends/api-error.js';

/** Firestore refuses a batch of more than 500 writes. A subtree can exceed it. */
const BATCH_LIMIT = 500;

/** The last code point Firestore will sort below, for a prefix range query. */
const HIGH_SENTINEL = '\uf8ff';

function chunk(items, size) {
  const out = [];
  for (let index = 0; index < items.length; index += size) {
    out.push(items.slice(index, index + size));
  }
  return out;
}

function reportFailure(error, doing) {
  const code = error?.code ?? '';
  if (code === 'permission-denied') {
    return new ApiError(
      `Your account is not allowed to ${doing}.`,
      'Publish the security rules in Web/firebase/firestore.rules, then try again.'
    );
  }
  if (code === 'unavailable' || code === 'failed-precondition') {
    return new ApiError(
      `The editor could not reach your cloud workspace while trying to ${doing}.`,
      'Check your network connection and try again.'
    );
  }
  if (code === 'unauthenticated') {
    return new ApiError('You are signed out.', 'Sign in again to reach your documents.');
  }
  return new ApiError(`Could not ${doing}.`, error?.message ?? '');
}

export async function createFirestoreNodeStore(uid) {
  const firebase = await loadFirebase();
  const {
    collection, doc, getDoc, getDocs, onSnapshot, query, where, writeBatch,
  } = firebase.firestore;

  const nodes = collection(firebase.db, USERS_COLLECTION, uid, NODES_COLLECTION);
  const refFor = (path) => doc(nodes, paths.documentId(path));

  async function runQuery(constraints, doing) {
    try {
      const snapshot = await getDocs(query(nodes, ...constraints));
      return snapshot.docs.map((entry) => entry.data());
    } catch (error) {
      throw reportFailure(error, doing);
    }
  }

  /**
   * A snapshot this browser caused, which the caller has already applied.
   *
   * Firestore answers a write locally before the server has acknowledged it,
   * so every save comes back through every listener within milliseconds. The
   * editor already has that text — it is what it just sent — and treating it
   * as an incoming change would mean re-rendering the pane out from under
   * whoever is typing. `hasPendingWrites` is exactly "this snapshot contains
   * a local write the server has not confirmed", so it is the precise signal
   * to skip, and it costs nothing to check.
   *
   * The server's own echo of the same write arrives later with the flag
   * cleared. That one is not skipped here — it is indistinguishable from
   * another device sending identical text, so it is compared by content
   * upstream, where the current text is known.
   */
  const isLocalEcho = (snapshot) => snapshot.metadata.hasPendingWrites;

  return {
    async read(path) {
      try {
        const snapshot = await getDoc(refFor(path));
        return snapshot.exists() ? snapshot.data() : null;
      } catch (error) {
        throw reportFailure(error, `open ${paths.nameOf(path)}`);
      }
    },

    /**
     * Equality on one field only, and sorted in the client afterwards.
     *
     * Adding `orderBy` to this would make it a composite query, which
     * Firestore will not serve until someone clicks through a console link to
     * build an index. A folder holds few enough entries to sort here, so the
     * app works the moment it is deployed instead of after a manual step.
     */
    childrenOf(parent) {
      return runQuery([where('parent', '==', parent)], 'list that folder');
    },

    /**
     * A range over `path`, then filtered.
     *
     * The filter is not belt-and-braces. `path >= 'Notes'` and
     * `path < 'Notes\uf8ff'` also matches `Notes 2/Out.md` and `Notes.md`,
     * because a range on a string knows nothing about separators — so
     * without this, renaming a folder would silently drag its similarly
     * named siblings along with it.
     */
    async subtreeOf(folder) {
      const rows = await runQuery(
        [where('path', '>=', folder), where('path', '<', `${folder}${HIGH_SENTINEL}`)],
        'read that folder'
      );
      return rows.filter(
        (row) => row.path === folder || row.path.startsWith(`${folder}/`)
      );
    },

    /**
     * Writes are chunked, and the chunks are applied in order.
     *
     * A batch is atomic; several batches are not. The backend orders its
     * writes so every create precedes the delete it replaces, which means an
     * interruption between chunks leaves documents duplicated rather than
     * lost. Losing nothing is the property worth having.
     */
    async commit(writes) {
      for (const group of chunk(writes, BATCH_LIMIT)) {
        const batch = writeBatch(firebase.db);
        for (const write of group) {
          if (write.remove) batch.delete(refFor(write.path));
          else batch.set(refFor(write.path), write.data);
        }
        try {
          await batch.commit();
        } catch (error) {
          throw reportFailure(error, 'save that change');
        }
      }
    },

    /**
     * WC-1: one folder level, pushed whenever it changes.
     *
     * The same `where('parent', '==', …)` as `childrenOf`, so it needs no
     * index and sees exactly what a fetch would see.
     *
     * A listener error is not thrown — there is no caller standing underneath
     * a callback to catch it. It is reported to the console and the
     * subscription is left in place, because Firestore retries a dropped
     * listener by itself and the editor keeps working from what it has.
     */
    watchChildren(parent, listener) {
      return onSnapshot(
        query(nodes, where('parent', '==', parent)),
        (snapshot) => {
          if (isLocalEcho(snapshot)) return;
          listener(snapshot.docs.map((entry) => entry.data()));
        },
        (error) => console.warn('Live folder updates stopped:', error?.code ?? error)
      );
    },

    /** WC-2: one node, pushed whenever it changes; `null` once it is gone. */
    watchNode(path, listener) {
      return onSnapshot(
        refFor(path),
        (snapshot) => {
          if (isLocalEcho(snapshot)) return;
          listener(snapshot.exists() ? snapshot.data() : null);
        },
        (error) => console.warn('Live document updates stopped:', error?.code ?? error)
      );
    },
  };
}

export async function createFirebaseAssetStore(uid) {
  const firebase = await loadFirebase();
  const {
    ref, uploadBytes, getDownloadURL, deleteObject, getBytes,
  } = firebase.storage;

  const objectFor = (storagePath) => ref(firebase.bucket, `users/${uid}/${storagePath}`);

  function storageFailure(error, doing) {
    const code = error?.code ?? '';
    if (code === 'storage/unauthorized') {
      return new ApiError(
        `Your account is not allowed to ${doing}.`,
        'Publish the rules in Web/firebase/storage.rules, and check that Storage is enabled.'
      );
    }
    if (code === 'storage/unknown' || code === 'storage/retry-limit-exceeded') {
      return new ApiError(
        `Could not ${doing}.`,
        'Check that Cloud Storage is enabled for this Firebase project, then try again.'
      );
    }
    return new ApiError(`Could not ${doing}.`, error?.message ?? '');
  }

  return {
    async upload(storagePath, file, contentType) {
      try {
        const object = objectFor(storagePath);
        await uploadBytes(object, file, contentType ? { contentType } : undefined);
        return await getDownloadURL(object);
      } catch (error) {
        throw storageFailure(error, `add ${paths.nameOf(storagePath)}`);
      }
    },

    /**
     * Copied through the client, because Storage has no server-side copy in
     * the web SDK. Images are capped at 10 MB, so this is a bounded download
     * and upload rather than an unbounded one.
     */
    async copy(from, to) {
      try {
        const source = objectFor(from);
        const bytes = await getBytes(source);
        const destination = objectFor(to);
        await uploadBytes(destination, bytes);
        return await getDownloadURL(destination);
      } catch (error) {
        throw storageFailure(error, 'duplicate that image');
      }
    },

    /**
     * Failures are swallowed one object at a time, on purpose. The Firestore
     * nodes are already gone by the time this runs; an orphaned object costs
     * a little storage, while a thrown error here would report a delete that
     * actually succeeded as a failure.
     */
    async removeAll(storagePaths) {
      await Promise.all(
        storagePaths.map(async (storagePath) => {
          try {
            await deleteObject(objectFor(storagePath));
          } catch {
            /* already gone, or never uploaded */
          }
        })
      );
    },
  };
}
