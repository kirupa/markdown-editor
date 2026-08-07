// The image cache: what makes a picture survive with no network.
//
// Firestore's persistent cache is asserted in `cloud-offline.test.js` and
// covers documents only. Cloud Storage objects are ordinary downloads, so
// without this an offline document opens with its text intact and every image
// broken. These tests use a store double and an injected downloader, so the
// decisions are exercised without IndexedDB and without a network.

import { suite, test, expect, expectEqual } from './harness.js';
import { createImageCache, nullImageCache } from '../app/cloud/image-cache.js';
import { createFirestoreBackend } from '../app/backends/firestore.js';
import {
  createMemoryNodeStore,
  createMemoryAssetStore,
  fileNode,
  folderNode,
  assetNode,
  fakeImage,
} from './support/memory-store.js';

/** A byte store that keeps rows in a Map and counts what was asked of it. */
function memoryImageStore(seed = {}) {
  const rows = new Map(Object.entries(seed));
  const calls = { get: 0, put: 0, forget: 0 };
  return {
    rows,
    calls,
    async get(url) {
      calls.get += 1;
      return rows.get(url) ?? null;
    },
    async put(url, bytes) {
      calls.put += 1;
      rows.set(url, bytes);
    },
    async forget(urls) {
      calls.forget += 1;
      for (const url of urls) rows.delete(url);
    },
  };
}

/** Stands in for a Blob; only `size` is ever read. */
function bytes(size = 12, tag = 'png') {
  return { size, tag };
}

/**
 * Builds a cache with recording stand-ins for the browser globals, so a test
 * can see exactly which URLs were minted and which were released.
 */
function cacheOver(store, { downloads = {}, offline = false } = {}) {
  const minted = [];
  const released = [];
  const asked = [];
  const cache = createImageCache({
    store,
    async download(url) {
      asked.push(url);
      if (offline) throw new Error('network unavailable');
      const found = downloads[url];
      if (!found) throw new Error(`404 ${url}`);
      return found;
    },
    toLocalURL(value) {
      const local = `blob:local/${minted.length}#${value.tag}`;
      minted.push(local);
      return local;
    },
    releaseLocalURL(url) {
      released.push(url);
    },
  });
  return { cache, minted, released, asked };
}

const REMOTE = 'https://firebasestorage.googleapis.com/o/photo.png?token=abc';

suite('Image cache', () => {
  test('an image is not local until it has been warmed', async () => {
    const { cache } = cacheOver(memoryImageStore());
    expectEqual(cache.localURLFor(REMOTE), null, 'nothing is cached yet');
  });

  test('bytes already on the device are adopted without a download', async () => {
    const store = memoryImageStore({ [REMOTE]: bytes() });
    const { cache, asked } = cacheOver(store);

    const summary = await cache.warm([REMOTE]);

    expectEqual(summary.cached, 1, 'the image was already here');
    expectEqual(summary.fetching, 0, 'so nothing had to be fetched');
    expectEqual(asked.length, 0, 'and the network was never touched');
    expect(cache.localURLFor(REMOTE)?.startsWith('blob:'), 'it renders from a local URL');
  });

  // The point of the whole module: this is the case that used to break.
  test('a warmed image still renders when the network is gone', async () => {
    const store = memoryImageStore();
    const first = cacheOver(store, { downloads: { [REMOTE]: bytes() } });
    await first.cache.warm([REMOTE]);
    await first.cache.settle();

    // A second device session: same store, no network at all.
    const { cache, asked } = cacheOver(store, { offline: true });
    await cache.warm([REMOTE]);

    expect(cache.localURLFor(REMOTE) !== null, 'the picture is still available');
    expectEqual(asked.length, 0, 'because it never needed the network');
  });

  test('warming an image that is not here yet does not block on the download', async () => {
    const store = memoryImageStore();
    const { cache, asked } = cacheOver(store, { downloads: { [REMOTE]: bytes() } });

    const summary = await cache.warm([REMOTE]);

    // The download URL works whenever the network does, so making a document
    // wait for its images would cost something real to save something that
    // only matters later.
    expectEqual(summary.fetching, 1, 'a fetch was started');
    expectEqual(cache.localURLFor(REMOTE), null, 'but warm did not wait for it');

    await cache.settle();
    expectEqual(asked.length, 1, 'the fetch happened in the background');
    expect(cache.localURLFor(REMOTE) !== null, 'and the bytes landed');
    expectEqual(store.rows.has(REMOTE), true, 'and were kept for next time');
  });

  test('being offline while warming leaves the cache empty rather than failing', async () => {
    const store = memoryImageStore();
    const { cache } = cacheOver(store, { offline: true });

    await cache.warm([REMOTE]);
    await cache.settle();

    expectEqual(cache.localURLFor(REMOTE), null, 'there is nothing to serve');
    expectEqual(store.calls.put, 0, 'and nothing was stored');
  });

  test('a failed download is never mistaken for image bytes', async () => {
    const store = memoryImageStore();
    // An error page has a body, so "it resolved" is not enough to cache it.
    const { cache } = cacheOver(store, { downloads: { [REMOTE]: bytes(0) } });

    await cache.warm([REMOTE]);
    await cache.settle();

    expectEqual(store.calls.put, 0, 'an empty body is not a picture');
    expectEqual(cache.localURLFor(REMOTE), null, 'and nothing is served from it');
  });

  test('uploaded bytes are cached without downloading them back', async () => {
    const store = memoryImageStore();
    const { cache, asked } = cacheOver(store);

    const local = await cache.remember(REMOTE, bytes());

    expect(local?.startsWith('blob:'), 'the new image renders immediately');
    expectEqual(asked.length, 0, 'the bytes were already in hand');
    expectEqual(store.rows.has(REMOTE), true, 'and they were kept');
  });

  test('warming twice does not fetch twice', async () => {
    const store = memoryImageStore();
    const { cache, asked } = cacheOver(store, { downloads: { [REMOTE]: bytes() } });

    await Promise.all([cache.warm([REMOTE]), cache.warm([REMOTE])]);
    await cache.settle();

    expectEqual(asked.length, 1, 'the second warm joined the first download');
  });

  test('a repeated URL in one document is fetched once', async () => {
    const store = memoryImageStore();
    const { cache, asked } = cacheOver(store, { downloads: { [REMOTE]: bytes() } });

    const summary = await cache.warm([REMOTE, REMOTE, REMOTE]);
    await cache.settle();

    expectEqual(summary.fetching, 1, 'the same picture used three times is one image');
    expectEqual(asked.length, 1, 'and one download');
  });

  // Replacing an image mints a new token, so the URL changes with the bytes.
  // That is why entries are keyed by URL: the cache cannot serve a stale
  // picture, it can only miss.
  test('replacing an image misses rather than serving the old one', async () => {
    const store = memoryImageStore({ [REMOTE]: bytes(10, 'old') });
    const replaced = `${REMOTE.split('?')[0]}?token=xyz`;
    const { cache } = cacheOver(store, { downloads: { [replaced]: bytes(10, 'new') } });

    await cache.warm([replaced]);
    expectEqual(cache.localURLFor(replaced), null, 'the new bytes are not here yet');
    await cache.settle();
    expect(cache.localURLFor(replaced)?.endsWith('#new'), 'and the new picture wins');
  });

  // Re-adopting would mint a second blob URL and revoke the first, and the
  // first is the one every `<img>` already on screen is pointing at.
  test('reopening a document reuses the local URL it already minted', async () => {
    const store = memoryImageStore({ [REMOTE]: bytes() });
    const { cache, minted, released } = cacheOver(store);
    await cache.warm([REMOTE]);
    const first = cache.localURLFor(REMOTE);

    await cache.warm([REMOTE]);

    expectEqual(cache.localURLFor(REMOTE), first, 'the same URL is still served');
    expectEqual(minted.length, 1, 'nothing new was minted');
    expectEqual(released.length, 0, 'and nothing on screen was revoked');
    expectEqual(store.calls.get, 1, 'the device was not read a second time');
  });

  test('replacing cached bytes releases the URL it supersedes', async () => {
    const store = memoryImageStore();
    const { cache, minted, released } = cacheOver(store);
    await cache.remember(REMOTE, bytes(10, 'first'));
    const first = cache.localURLFor(REMOTE);

    await cache.remember(REMOTE, bytes(10, 'second'));

    expectEqual(minted.length, 2, 'the new bytes got their own URL');
    expectEqual(released[0], first, 'and the old one was released, not leaked');
  });

  test('forgetting an image drops its bytes and releases its local URL', async () => {
    const store = memoryImageStore({ [REMOTE]: bytes() });
    const { cache, released } = cacheOver(store);
    await cache.warm([REMOTE]);
    const local = cache.localURLFor(REMOTE);

    await cache.forget([REMOTE]);

    expectEqual(cache.localURLFor(REMOTE), null, 'it is no longer served');
    expectEqual(store.rows.has(REMOTE), false, 'and the bytes are gone');
    expectEqual(released[0], local, 'and the blob URL was released, not leaked');
  });

  test('deleting a folder of mixed nodes forgets only the images', async () => {
    const store = memoryImageStore({ [REMOTE]: bytes() });
    const { cache } = cacheOver(store);
    await cache.warm([REMOTE]);

    // Folders and documents have no `url`; the backend passes the whole subtree.
    await cache.forget([undefined, REMOTE, null, '']);

    expectEqual(store.rows.size, 0, 'the image went');
    expectEqual(store.calls.forget, 1, 'in one call');
  });

  test('a store that cannot keep the bytes still renders this session', async () => {
    const store = memoryImageStore();
    store.put = async () => { throw new Error('QuotaExceededError'); };
    const { cache } = cacheOver(store, { downloads: { [REMOTE]: bytes() } });

    await cache.warm([REMOTE]);
    await cache.settle();

    expect(cache.localURLFor(REMOTE) !== null, 'private browsing still shows pictures');
  });

  test('the null cache answers for every backend that has no images to keep', async () => {
    const cache = nullImageCache();
    expectEqual(cache.localURLFor(REMOTE), null, 'nothing is ever local');
    expectEqual((await cache.warm([REMOTE])).cached, 0, 'and warming is a no-op');
    await cache.forget([REMOTE]);
  });
});

// The module above can be perfect and still never be reached. These assert the
// wiring: that the backend warms on read, remembers on upload, prefers the
// local copy when rendering, and forgets on delete.
suite('Image cache in the cloud backend', () => {
  /** Builds a backend whose cache is backed by a Map, with no network at all. */
  function build(seed = [], { offline = false, stored = {} } = {}) {
    const nodes = createMemoryNodeStore(seed);
    const assets = createMemoryAssetStore();
    const store = memoryImageStore(stored);
    const downloaded = [];
    const images = createImageCache({
      store,
      async download(url) {
        downloaded.push(url);
        if (offline) throw new Error('network unavailable');
        return bytes(64, 'downloaded');
      },
      toLocalURL: (value) => `blob:local/${value.tag}`,
      releaseLocalURL: () => {},
    });
    return {
      nodes, assets, store, images, downloaded,
      backend: createFirestoreBackend({ nodes, assets, images }),
    };
  }

  const IMAGE_URL = 'https://firebasestorage.googleapis.com/o/Trip.assets%2Fbeach.png?token=t1';

  function documentWithAnImage() {
    return [
      fileNode('Trip.md', '# Trip\n\n![beach](Trip.assets/beach.png)\n'),
      folderNode('Trip.assets'),
      { ...assetNode('Trip.assets/beach.png'), url: IMAGE_URL },
    ];
  }

  test('opening a document warms the images it refers to', async () => {
    const { backend, downloaded, store } = build(documentWithAnImage());

    await backend.read('Trip.md');
    await new Promise((resolve) => setTimeout(resolve, 0));

    expectEqual(downloaded[0], IMAGE_URL, 'the image was fetched for next time');
    expectEqual(store.rows.has(IMAGE_URL), true, 'and kept on the device');
  });

  test('an image already on the device renders offline', async () => {
    const { backend, downloaded } = build(documentWithAnImage(), {
      offline: true,
      stored: { [IMAGE_URL]: bytes(64, 'cached') },
    });

    await backend.read('Trip.md');

    expectEqual(
      backend.imageURL('Trip.assets/beach.png'),
      'blob:local/cached',
      'the picture comes from the device, not the network'
    );
    expectEqual(downloaded.length, 0, 'with no request at all');
  });

  // The regression this whole module exists to prevent.
  test('with no network and nothing cached the remote URL is still returned', async () => {
    const { backend } = build(documentWithAnImage(), { offline: true });

    await backend.read('Trip.md');

    expectEqual(
      backend.imageURL('Trip.assets/beach.png'),
      IMAGE_URL,
      'a cache miss must never turn into a missing image'
    );
  });

  test('an uploaded image is offline-ready at once', async () => {
    const { backend, store, downloaded } = build([fileNode('Trip.md', '# Trip')]);

    await backend.uploadImage('Trip.md', fakeImage('beach.png'));

    expectEqual(store.rows.size, 1, 'the bytes just sent were kept');
    expectEqual(downloaded.length, 0, 'without downloading them back');
    expect(
      backend.imageURL('Trip.assets/beach.png')?.startsWith('blob:'),
      'and the new picture renders from the device'
    );
  });

  test('renaming a document keeps its images cached', async () => {
    const { backend } = build(documentWithAnImage(), {
      stored: { [IMAGE_URL]: bytes(64, 'cached') },
    });
    await backend.read('Trip.md');

    await backend.rename('Trip.md', 'Holiday.md');

    // Entries are keyed by download URL, so a move needs no cache bookkeeping.
    expectEqual(
      backend.imageURL('Holiday.assets/beach.png'),
      'blob:local/cached',
      'the picture followed the document'
    );
  });

  test('deleting a document forgets the bytes of its images', async () => {
    const { backend, store } = build(documentWithAnImage(), {
      stored: { [IMAGE_URL]: bytes(64, 'cached') },
    });
    await backend.read('Trip.md');

    await backend.remove('Trip.assets');

    expectEqual(store.rows.size, 0, 'the device does not keep deleted pictures');
  });
});
