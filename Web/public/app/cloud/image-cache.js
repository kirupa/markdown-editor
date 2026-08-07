// Keeps image bytes on the device so pictures still render with no network.
//
// Firestore's persistent cache covers documents and nothing else. Cloud Storage
// objects are ordinary HTTPS downloads, so offline every `<img>` in a cached
// document points at a host the browser cannot reach and the document opens
// full of broken images. The text survives and the pictures do not, which is
// the worst of both: the document looks damaged rather than unavailable.
//
// Entries are keyed by *download URL*, not by the path of the image in the
// workspace. Two properties fall out of that and both matter:
//
//   * Renaming a document moves its images, and `recache` in the backend
//     carries each URL across to the new path. A cache keyed by path would have
//     to be told; keyed by URL there is nothing to tell.
//   * A download URL carries a token that changes when the object's bytes are
//     replaced. Replacing an image therefore misses rather than serving the old
//     picture, so the cache cannot go stale — it can only be empty.
//
// The store is injected because IndexedDB does not exist under node, and every
// decision here is worth testing without a browser.

/**
 * @typedef {object} ImageByteStore
 * @property {(url: string) => Promise<Blob | null>} get
 * @property {(url: string, bytes: Blob) => Promise<void>} put
 * @property {(urls: string[]) => Promise<void>} forget
 */

/** Never cache a download that came back as an error page or an empty body. */
function isUsable(bytes) {
  return Boolean(bytes) && bytes.size > 0;
}

/**
 * @param {object} options
 * @param {ImageByteStore} options.store
 * @param {(url: string) => Promise<Blob>} [options.download] defaults to `fetch`
 * @param {(bytes: Blob) => string} [options.toLocalURL] defaults to `URL.createObjectURL`
 * @param {(url: string) => void} [options.releaseLocalURL] defaults to `URL.revokeObjectURL`
 */
export function createImageCache({
  store,
  download = defaultDownload,
  toLocalURL = (bytes) => URL.createObjectURL(bytes),
  releaseLocalURL = (url) => URL.revokeObjectURL(url),
} = {}) {
  /** Download URL -> `blob:` URL usable with no network. */
  const localByRemote = new Map();
  /** Downloads in flight, so warming twice does not fetch twice. */
  const pending = new Map();

  function publish(remoteURL, bytes) {
    const existing = localByRemote.get(remoteURL);
    if (existing) releaseLocalURL(existing);
    const local = toLocalURL(bytes);
    localByRemote.set(remoteURL, local);
    return local;
  }

  async function adopt(remoteURL) {
    const bytes = await store.get(remoteURL);
    if (!isUsable(bytes)) return null;
    return publish(remoteURL, bytes);
  }

  async function pull(remoteURL) {
    let bytes;
    try {
      bytes = await download(remoteURL);
    } catch {
      // Offline, or the object is gone. Either way the remote URL is still the
      // best answer available, and a failed warm must never fail the read that
      // asked for it.
      return null;
    }
    if (!isUsable(bytes)) return null;
    try {
      await store.put(remoteURL, bytes);
    } catch {
      /* out of quota, or private browsing; serving it this session still works */
    }
    return publish(remoteURL, bytes);
  }

  return {
    /**
     * The URL to render, answered synchronously because the renderer resolves
     * image sources while it builds the DOM. `null` means "no local copy" —
     * the caller falls back to the download URL.
     */
    localURLFor(remoteURL) {
      if (!remoteURL) return null;
      return localByRemote.get(remoteURL) ?? null;
    },

    /**
     * Records bytes the caller already holds. Used when an image is uploaded:
     * those bytes are in memory at that moment, so the picture just added is
     * offline-ready without downloading back what was sent.
     */
    async remember(remoteURL, bytes) {
      if (!remoteURL || !isUsable(bytes)) return null;
      try {
        await store.put(remoteURL, bytes);
      } catch {
        /* see `pull` */
      }
      return publish(remoteURL, bytes);
    },

    /**
     * Makes the given images renderable offline.
     *
     * Local hits are awaited, because opening a document must not race the
     * render that follows it. Misses are *not* awaited: a miss means the bytes
     * have to come over the network, and if the network is there the download
     * URL already works. Blocking a document on downloading its images would
     * trade a real cost today for a hypothetical one later.
     */
    async warm(remoteURLs) {
      const wanted = [...new Set((remoteURLs ?? []).filter(Boolean))];
      const misses = [];
      await Promise.all(wanted.map(async (remoteURL) => {
        if (localByRemote.has(remoteURL)) return;
        if (await adopt(remoteURL)) return;
        misses.push(remoteURL);
      }));
      for (const remoteURL of misses) {
        if (pending.has(remoteURL)) continue;
        const run = pull(remoteURL).finally(() => pending.delete(remoteURL));
        pending.set(remoteURL, run);
      }
      return { cached: wanted.length - misses.length, fetching: misses.length };
    },

    /** Waits for the background downloads `warm` started. For tests. */
    async settle() {
      await Promise.all([...pending.values()]);
    },

    /** Drops bytes for images that no longer exist. */
    async forget(remoteURLs) {
      const gone = (remoteURLs ?? []).filter(Boolean);
      if (gone.length === 0) return;
      for (const remoteURL of gone) {
        const local = localByRemote.get(remoteURL);
        if (local) releaseLocalURL(local);
        localByRemote.delete(remoteURL);
      }
      try {
        await store.forget(gone);
      } catch {
        /* the bytes are unreachable anyway; a stale row is harmless */
      }
    },
  };
}

async function defaultDownload(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`image download failed: ${response.status}`);
  return await response.blob();
}

/** A cache that holds nothing, for the local backend and for tests. */
export function nullImageCache() {
  return {
    localURLFor: () => null,
    remember: async () => null,
    warm: async () => ({ cached: 0, fetching: 0 }),
    settle: async () => {},
    forget: async () => {},
  };
}
