// A Firestore stand-in, and a Storage stand-in, both in memory.
//
// These exist so the cloud backend can be tested without a network, an
// account, or the SDK. They are not sketches: a query by parent sees only
// direct children, a subtree query is a real prefix query, and a commit is
// applied only after every write in it validates — because a double that is
// more forgiving than the real thing tests nothing.

import { firestoreRuleViolation } from './security-rules.js';

export function createMemoryNodeStore(seed = []) {
  const rows = new Map(seed.map((node) => [node.path, node]));

  /**
   * Watchers, and the rule for who hears about a change.
   *
   * Modelled on the real listener rather than simplified: attaching delivers
   * the current contents straight away, exactly as Firestore does, because
   * that first delivery is the thing callers have to be careful about.
   */
  const childWatchers = new Set();
  const nodeWatchers = new Set();

  const childrenNow = (parent) =>
    [...rows.values()].filter((row) => (row.parent ?? '') === parent).map((row) => ({ ...row }));

  function announce(paths) {
    const parents = new Set();
    for (const path of paths) {
      const cut = path.lastIndexOf('/');
      parents.add(cut === -1 ? '' : path.slice(0, cut));
    }
    for (const watcher of childWatchers) {
      if (parents.has(watcher.parent)) watcher.listener(childrenNow(watcher.parent));
    }
    for (const watcher of nodeWatchers) {
      if (!paths.includes(watcher.path)) continue;
      const row = rows.get(watcher.path);
      watcher.listener(row ? { ...row } : null);
    }
  }

  return {
    snapshot: () => Object.fromEntries([...rows].map(([k, v]) => [k, { ...v }])),
    paths: () => [...rows.keys()].sort(),

    /** How many listeners are attached, so leaks are visible to a test. */
    watcherCount: () => childWatchers.size + nodeWatchers.size,

    /**
     * A change made somewhere else — another device, or another tab.
     *
     * Separate from `commit` only to read clearly at the call site; both
     * notify, because the real store filters this browser's own echo one layer
     * lower, in `firestore-store.js`, where the SDK metadata is available.
     */
    remoteWrite(node) {
      rows.set(node.path, { ...node });
      announce([node.path]);
    },

    remoteDelete(path) {
      rows.delete(path);
      announce([path]);
    },

    async read(path) {
      const row = rows.get(path);
      return row ? { ...row } : null;
    },

    async childrenOf(parent) {
      return childrenNow(parent);
    },

    async subtreeOf(folder) {
      // The real query is `path >= folder` and `path < folder + '\uf8ff'`.
      // That range also catches a sibling whose name merely starts with the
      // same letters — "Notes 2" alongside "Notes" — so the boundary is drawn
      // the same way here, on a separator, and not with a bare startsWith.
      return [...rows.values()]
        .filter((row) => row.path === folder || row.path.startsWith(`${folder}/`))
        .map((row) => ({ ...row }))
        .sort((a, b) => a.path.localeCompare(b.path));
    },

    async commit(writes) {
      for (const write of writes) {
        if (!write.path) throw new Error('a write with no path');
        if (!write.remove && !write.data) throw new Error('a write with no data');
        // The published rules refuse malformed writes, so this double does
        // too. Without it a write the server rejects passes every test.
        const violation = write.remove ? null : firestoreRuleViolation(write.data);
        if (violation) throw new Error(`${write.path}: ${violation}`);
      }
      for (const write of writes) {
        if (write.remove) rows.delete(write.path);
        else rows.set(write.path, { ...write.data });
      }
      announce(writes.map((write) => write.path));
    },

    watchChildren(parent, listener) {
      const watcher = { parent, listener };
      childWatchers.add(watcher);
      listener(childrenNow(parent));
      return () => childWatchers.delete(watcher);
    },

    watchNode(path, listener) {
      const watcher = { path, listener };
      nodeWatchers.add(watcher);
      const row = rows.get(path);
      listener(row ? { ...row } : null);
      return () => nodeWatchers.delete(watcher);
    },
  };
}

export function createMemoryAssetStore() {
  const bytes = new Map();
  const types = new Map();
  let counter = 0;

  return {
    bytes,
    types,
    async upload(storagePath, file, contentType) {
      bytes.set(storagePath, file);
      // Recorded because the Storage rules only accept `image/*`: an upload
      // that loses its type is refused by the server, not by this double.
      types.set(storagePath, contentType);
      counter += 1;
      return `https://storage.test/${counter}`;
    },
    async copy(from, to) {
      if (!bytes.has(from)) throw new Error(`copying bytes that are not there: ${from}`);
      bytes.set(to, bytes.get(from));
      counter += 1;
      return `https://storage.test/${counter}`;
    },
    async removeAll(storagePaths) {
      for (const path of storagePaths) bytes.delete(path);
    },
  };
}

function split(path) {
  const cut = path.lastIndexOf('/');
  return {
    parent: cut === -1 ? '' : path.slice(0, cut),
    name: cut === -1 ? path : path.slice(cut + 1),
  };
}

export function fileNode(path, text = '') {
  return { type: 'file', path, ...split(path), text, hasByteOrderMark: false, size: text.length, modified: 1 };
}

export function folderNode(path) {
  return { type: 'folder', path, ...split(path), modified: 1 };
}

export function assetNode(path, storagePath = `${path}#1`) {
  return {
    type: 'asset',
    path,
    ...split(path),
    storagePath,
    url: `https://storage.test/seed/${storagePath}`,
    contentType: 'image/png',
    size: 4,
    modified: 1,
  };
}

/** A File stand-in: the backend reads only name, size, and type. */
export function fakeImage(name, { size = 1024, type = 'image/png' } = {}) {
  return { name, size, type };
}
