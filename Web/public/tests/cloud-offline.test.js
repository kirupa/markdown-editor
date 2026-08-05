// How the cloud workspace behaves when the network is not there.
//
// The interesting decision is made once, at the moment Firestore is opened,
// and it is invisible afterwards: a client opened the default way keeps its
// cache in memory and forgets everything on reload, and one opened with a
// persistent cache does not. Nothing downstream looks different, no test that
// exercises reading or writing would notice, and the failure only shows up on
// a real device with no signal. So it is asserted here, at the seam.

import { suite, test, expectEqual, expectThrows } from './harness.js';
import { openFirestore } from '../app/cloud/sdk.js';

/**
 * Stands in for the `firebase-firestore.js` module. Records what was asked for
 * rather than doing it, and each factory returns a tagged object so the
 * assertions can tell the two kinds of cache apart.
 */
function fakeFirestoreModule({ persistenceFails = false } = {}) {
  const calls = [];
  return {
    calls,
    initializeFirestore(app, settings) {
      calls.push('initializeFirestore');
      if (persistenceFails) throw new Error('IndexedDB is unavailable');
      return { kind: 'persistent', app, settings };
    },
    getFirestore(app) {
      calls.push('getFirestore');
      return { kind: 'memory', app };
    },
    persistentLocalCache(settings) {
      calls.push('persistentLocalCache');
      return { cache: 'persistent', ...settings };
    },
    persistentMultipleTabManager() {
      calls.push('persistentMultipleTabManager');
      return { tabs: 'multiple' };
    },
  };
}

suite('Opening Firestore for offline use', () => {
  test('asks for a cache that outlives the tab, not the default in-memory one', () => {
    const firestore = fakeFirestoreModule();
    const db = openFirestore(firestore, { name: 'app' });

    expectEqual(db.kind, 'persistent');
    expectEqual(db.settings.localCache.cache, 'persistent');
  });

  test('does not fall back to the in-memory client when persistence works', () => {
    const firestore = fakeFirestoreModule();
    openFirestore(firestore, { name: 'app' });

    // The whole point of the change: `getFirestore` is the call that gives a
    // client which forgets everything on reload, so it must not be reached.
    expectEqual(firestore.calls.includes('getFirestore'), false);
  });

  test('uses the multi-tab manager, so a second tab is not left without a cache', () => {
    const firestore = fakeFirestoreModule();
    const db = openFirestore(firestore, { name: 'app' });

    expectEqual(db.settings.localCache.tabManager.tabs, 'multiple');
    expectEqual(firestore.calls.includes('persistentMultipleTabManager'), true);
  });

  test('still opens when the browser will not store anything', () => {
    // Private browsing, or IndexedDB switched off. Losing offline support is
    // acceptable; refusing to open the editor at all is not.
    const firestore = fakeFirestoreModule({ persistenceFails: true });
    const warnings = [];
    const realWarn = console.warn;
    console.warn = (...args) => warnings.push(args);
    try {
      const db = openFirestore(firestore, { name: 'app' });
      expectEqual(db.kind, 'memory');
      expectEqual(warnings.length, 1);
    } finally {
      console.warn = realWarn;
    }
  });

  test('a browser with neither client available fails loudly rather than silently', () => {
    // If both paths are gone the SDK has changed shape under us, and a
    // `db` of `undefined` would surface much later as an unreadable error.
    const broken = {
      initializeFirestore() {
        throw new Error('IndexedDB is unavailable');
      },
      getFirestore() {
        throw new Error('no client');
      },
      persistentLocalCache: () => ({}),
      persistentMultipleTabManager: () => ({}),
    };
    const realWarn = console.warn;
    console.warn = () => {};
    try {
      expectThrows(() => openFirestore(broken, { name: 'app' }));
    } finally {
      console.warn = realWarn;
    }
  });
});
