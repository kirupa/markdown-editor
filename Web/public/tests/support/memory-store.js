// A Firestore stand-in, and a Storage stand-in, both in memory.
//
// These exist so the cloud backend can be tested without a network, an
// account, or the SDK. They are not sketches: a query by parent sees only
// direct children, a subtree query is a real prefix query, and a commit is
// applied only after every write in it validates — because a double that is
// more forgiving than the real thing tests nothing.

export function createMemoryNodeStore(seed = []) {
  const rows = new Map(seed.map((node) => [node.path, node]));

  return {
    snapshot: () => Object.fromEntries([...rows].map(([k, v]) => [k, { ...v }])),
    paths: () => [...rows.keys()].sort(),

    async read(path) {
      const row = rows.get(path);
      return row ? { ...row } : null;
    },

    async childrenOf(parent) {
      return [...rows.values()]
        .filter((row) => (row.parent ?? '') === parent)
        .map((row) => ({ ...row }));
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
      }
      for (const write of writes) {
        if (write.remove) rows.delete(write.path);
        else rows.set(write.path, { ...write.data });
      }
    },
  };
}

export function createMemoryAssetStore() {
  const bytes = new Map();
  let counter = 0;

  return {
    bytes,
    async upload(storagePath, file) {
      bytes.set(storagePath, file);
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
