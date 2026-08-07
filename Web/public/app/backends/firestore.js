// The Firestore-backed storage backend: documents in the signed-in account.
//
// Firestore has no folders. What it has is a flat collection of nodes, each
// carrying the path it *would* have on a disk, and a tree is a reading of that
// field. So everything the filesystem did for free — listing a folder, renaming
// a subtree, refusing to overwrite — is written out here, on top of the path
// arithmetic in `paths.js`.
//
// The Firestore SDK is not imported. This module talks to a `NodeStore`, four
// methods wide, which `firestore-store.js` implements against the real database
// and which the tests implement in memory. That split is deliberate: the part
// with the decisions in it — collisions, subtree moves, what counts as a
// descendant — is the part that runs under test, and the part that cannot be
// tested without a network is small enough to read in one sitting.
//
// Node shape:
//   { type: 'folder' | 'file' | 'asset',
//     path, parent, name,
//     text, hasByteOrderMark, size,          // file
//     storagePath, url, contentType,         // asset
//     modified }

import { ApiError } from './api-error.js';
import * as paths from '../cloud/paths.js';

/** Image formats the local build accepts, so both modes take the same files. */
const IMAGE_EXTENSIONS = [
  'png', 'jpg', 'jpeg', 'gif', 'heic', 'heif', 'tiff', 'tif', 'bmp', 'webp', 'svg',
];

/**
 * The type to record when the browser does not supply one.
 *
 * `File.type` is empty surprisingly often — dragging from some applications,
 * and anything constructed by hand — and an upload with no type is stored as
 * `application/octet-stream`. The Storage rules only accept `image/*`, so an
 * image that arrives without a type is refused by the server, which the user
 * sees as an image that silently will not add. The extension is already
 * checked against IMAGE_EXTENSIONS by then, so the type can be derived from
 * it rather than guessed.
 */
const IMAGE_TYPES = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif',
  heic: 'image/heic', heif: 'image/heif', tiff: 'image/tiff', tif: 'image/tiff',
  bmp: 'image/bmp', webp: 'image/webp', svg: 'image/svg+xml',
};

function imageTypeFor(file, extension) {
  const declared = (file.type || '').toLowerCase();
  if (declared.startsWith('image/')) return declared;
  return IMAGE_TYPES[extension] ?? 'application/octet-stream';
}

/**
 * A cap on a single image, since Storage imposes no useful one of its own.
 * The local build's limit comes from PHP's `upload_max_filesize`; this is the
 * cloud equivalent, chosen to be larger than any screenshot and smaller than
 * anything that would make a document slow to open.
 */
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;

// Firestore caps a document at 1 MiB, and `firestore.rules` refuses a longer
// one. Checking here as well turns a rules rejection — which arrives as a bare
// permission error, indistinguishable from being signed out — into a sentence
// that says what happened. The native builds check the same number.
const MAX_DOCUMENT_BYTES = 900_000;

/**
 * @typedef {object} NodeStore
 * @property {(path: string) => Promise<object|null>} read one node, or null
 * @property {(parent: string) => Promise<object[]>} childrenOf one level
 * @property {(folder: string) => Promise<object[]>} subtreeOf the folder and everything under it
 * @property {(writes: Array<{path: string, data?: object, remove?: boolean}>) => Promise<void>} commit
 * @property {(parent: string, listener: (nodes: object[]) => void) => () => void} watchChildren
 *   calls back with one level whenever it changes; returns an unsubscribe
 * @property {(path: string, listener: (node: object|null) => void) => () => void} watchNode
 *   calls back with one node, or null once it is gone; returns an unsubscribe
 */

/**
 * @typedef {object} AssetStore
 * @property {(storagePath: string, file: Blob, contentType: string) => Promise<string>} upload returns a download URL
 * @property {(storagePaths: string[]) => Promise<void>} removeAll
 * @property {(from: string, to: string) => Promise<string>} copy returns the new download URL
 */

export function createFirestoreBackend({ nodes, assets, workspaceName = 'kirupaMarkdown' }) {
  // `imageURL` has to answer synchronously, because the renderer resolves image
  // sources while it builds the DOM. Reading a document fills this in for the
  // images that document refers to, so by the time anything renders the answer
  // is already here.
  const urlByPath = new Map();

  /**
   * Keeps the URL cache in step when a path changes.
   *
   * The renderer resolves image sources synchronously while it builds the DOM,
   * and renaming the open document does not reload it — the model is relocated
   * in place. So a moved image has to be reachable under its new path straight
   * away, or every image in the document breaks until the page is reloaded.
   */
  function recache(fromPath, toPath, url) {
    const cached = urlByPath.get(fromPath);
    if (url !== undefined) {
      // A copy owns fresh bytes at a fresh URL, and the original stays put.
      urlByPath.set(toPath, url);
      return;
    }
    urlByPath.delete(fromPath);
    if (cached !== undefined) urlByPath.set(toPath, cached);
  }

  function entryFor(node) {
    const isDirectory = node.type === 'folder';
    return {
      name: node.name,
      path: node.path,
      parent: paths.parentOf(node.path),
      isDirectory,
      isSymbolicLink: false,
      isPackage: false,
      isExpandable: isDirectory,
      isMarkdown: !isDirectory && paths.isMarkdown(node.name),
    };
  }

  function folderNode(path) {
    return {
      type: 'folder',
      path,
      parent: paths.parentOf(path),
      name: paths.nameOf(path),
      modified: Date.now(),
    };
  }

  async function requireNode(path, what = 'item') {
    const normalized = paths.normalize(path);
    if (normalized === '') {
      throw new ApiError(`The workspace itself is not a ${what}.`);
    }
    const node = await nodes.read(normalized);
    if (!node) {
      throw new ApiError(
        `That ${what} is no longer in your account: ${paths.nameOf(normalized)}`,
        'It may have been deleted from another device.'
      );
    }
    return node;
  }

  /** Creates any missing folders above `path`, so a tree is never broken. */
  async function ensureAncestors(path, writes) {
    for (const folder of paths.ancestorFolders(path)) {
      const existing = await nodes.read(folder);
      if (existing && existing.type !== 'folder') {
        throw new ApiError(
          `A document is in the way of that location: ${paths.nameOf(folder)}`,
          'Rename it, or choose a different folder.'
        );
      }
      if (!existing) writes.push({ path: folder, data: folderNode(folder) });
    }
  }

  async function assertAvailable(path) {
    const existing = await nodes.read(path);
    if (existing) {
      throw new ApiError(
        `Something already exists at that location: ${paths.nameOf(path)}`,
        'Choose a different name.'
      );
    }
  }

  async function takenNamesIn(parent) {
    const siblings = await nodes.childrenOf(parent);
    return new Set(siblings.map((node) => node.name));
  }

  /**
   * Moves or copies a document's `<stem>.assets` folder along with it, and
   * rewrites the references inside the document so they still resolve.
   *
   * The local build does exactly this in FileManager::carryAssets. Leaving it
   * out would mean a rename silently broke every image in the document.
   */
  async function carryAssets(fromDocument, toDocument, { copy }, writes) {
    if (!paths.isMarkdown(fromDocument)) return null;

    const oldFolderName = paths.assetsFolderName(fromDocument);
    const newFolderName = paths.assetsFolderName(toDocument);
    if (oldFolderName === '.assets' || newFolderName === '.assets') return null;

    const oldFolder = paths.join(paths.parentOf(fromDocument), oldFolderName);
    const newFolder = paths.join(paths.parentOf(toDocument), newFolderName);
    if (oldFolder === newFolder) return null;

    const subtree = await nodes.subtreeOf(oldFolder);
    if (subtree.length === 0) return null;

    await assertAvailable(newFolder);

    for (const node of subtree) {
      const destination = paths.rewrite(node.path, oldFolder, newFolder);
      const moved = { ...node, path: destination, parent: paths.parentOf(destination) };

      if (copy && node.type === 'asset') {
        // A copied document must not share image bytes with its original;
        // deleting one would break the other.
        const storagePath = `${destination}#${Date.now()}`;
        moved.storagePath = storagePath;
        moved.url = await assets.copy(node.storagePath, storagePath);
      }

      writes.push({ path: destination, data: moved });
      if (!copy) writes.push({ path: node.path, remove: true });
      if (node.type === 'asset') recache(node.path, destination, copy ? moved.url : undefined);
    }

    return { oldFolderName, newFolderName };
  }

  /** Swaps `old.assets/` for `new.assets/` in a document's own text. */
  function rewriteAssetReferences(text, oldFolderName, newFolderName) {
    if (!text) return text;
    const from = paths.encodeComponent(oldFolderName);
    const to = paths.encodeComponent(newFolderName);
    // Only as the leading component of a reference, so a folder name that also
    // appears in prose is left alone.
    return text
      .split(`](${from}/`).join(`](${to}/`)
      .split(`](${oldFolderName}/`).join(`](${newFolderName}/`);
  }

  async function relocate(fromPath, toPath, verb) {
    const source = paths.normalize(fromPath);
    const destination = paths.normalize(toPath);
    if (source === destination) return entryFor(await requireNode(source));

    const node = await requireNode(source);
    if (node.type === 'folder' && paths.isDescendantOf(destination, source)) {
      throw new ApiError(
        `A folder cannot be ${verb} into itself.`,
        'Choose a folder outside it.'
      );
    }
    await assertAvailable(destination);

    const writes = [];
    await ensureAncestors(destination, writes);

    const renamed = await carryAssets(source, destination, { copy: false }, writes);
    const subtree = await nodes.subtreeOf(source);

    for (const member of subtree) {
      const target = paths.rewrite(member.path, source, destination);
      const moved = {
        ...member,
        path: target,
        parent: paths.parentOf(target),
        name: paths.nameOf(target),
        modified: Date.now(),
      };
      if (renamed && member.path === source && typeof moved.text === 'string') {
        moved.text = rewriteAssetReferences(
          moved.text, renamed.oldFolderName, renamed.newFolderName
        );
      }
      writes.push({ path: target, data: moved });
      writes.push({ path: member.path, remove: true });
    }

    await nodes.commit(writes);

    // Renaming a folder moves any assets inside it; the sibling assets folder
    // of a renamed document is handled by carryAssets above.
    for (const member of subtree) {
      if (member.type !== 'asset') continue;
      recache(member.path, paths.rewrite(member.path, source, destination));
    }

    return entryFor({ ...node, path: destination, name: paths.nameOf(destination) });
  }

  return {
    id: 'cloud',

    async config() {
      return {
        workspaceName,
        markdownExtensions: paths.MARKDOWN_EXTENSIONS,
        imageExtensions: IMAGE_EXTENSIONS,
        maxUploadBytes: MAX_IMAGE_BYTES,
      };
    },

    async tree(path = '') {
      const folder = paths.normalize(path);
      if (folder !== '') {
        const node = await requireNode(folder, 'folder');
        if (node.type !== 'folder') {
          throw new ApiError(`That is not a folder: ${node.name}`);
        }
      }
      const children = await nodes.childrenOf(folder);
      return {
        path: folder,
        entries: children.map(entryFor).sort(paths.compareEntries),
        ancestors: paths.ancestorsOf(folder, workspaceName),
      };
    },

    async read(path) {
      const node = await requireNode(path, 'document');
      if (node.type === 'folder') {
        throw new ApiError(`That is a folder, not a Markdown document: ${node.name}`);
      }
      if (!paths.isMarkdown(node.name)) {
        throw new ApiError(
          'Only .md and .markdown files can be opened.',
          `The file ${node.name} has a different extension.`
        );
      }

      // Fill the image cache before anything renders (see `urlByPath`).
      const assetFolder = paths.join(
        paths.parentOf(node.path),
        paths.assetsFolderName(node.path)
      );
      for (const asset of await nodes.subtreeOf(assetFolder)) {
        if (asset.type === 'asset' && asset.url) urlByPath.set(asset.path, asset.url);
      }

      const text = node.text ?? '';
      return {
        path: node.path,
        name: node.name,
        text,
        hasByteOrderMark: Boolean(node.hasByteOrderMark),
        modified: node.modified ?? 0,
        size: new TextEncoder().encode(text).length,
      };
    },

    async exists(path) {
      const normalized = paths.normalize(path);
      if (normalized === '') return { path: normalized, exists: false };
      const node = await nodes.read(normalized);
      return {
        path: normalized,
        exists: Boolean(node) && node.type === 'file' && paths.isMarkdown(node.name),
      };
    },

    async write(path, text, hasByteOrderMark = false) {
      const target = paths.normalize(path);
      if (!paths.isMarkdown(target)) {
        throw new ApiError(
          'Markdown documents must end in .md or .markdown.',
          `Rename ${paths.nameOf(target)} and try again.`
        );
      }
      const existing = await nodes.read(target);
      if (existing && existing.type === 'folder') {
        throw new ApiError(`A folder already exists at that location: ${existing.name}`);
      }

      const writes = [];
      await ensureAncestors(target, writes);
      const size = new TextEncoder().encode(text ?? '').length;
      if (size >= MAX_DOCUMENT_BYTES) {
        throw new ApiError(
          `That document is too large to save to the cloud: ${paths.nameOf(target)}`,
          `Cloud documents must be under ${Math.round(MAX_DOCUMENT_BYTES / 1000)} KB, and this one is ${Math.round(size / 1000)} KB. Split it, or switch this document to local storage.`
        );
      }
      const modified = Date.now();
      writes.push({
        path: target,
        data: {
          type: 'file',
          path: target,
          parent: paths.parentOf(target),
          name: paths.nameOf(target),
          text: text ?? '',
          hasByteOrderMark: Boolean(hasByteOrderMark),
          size,
          modified,
        },
      });
      await nodes.commit(writes);

      return { path: target, name: paths.nameOf(target), modified, size };
    },

    async create(path) {
      const target = paths.normalize(path);
      await assertAvailable(target);
      return this.write(target, '');
    },

    async newFolder(parent, name) {
      const folder = paths.normalize(parent);
      const taken = await takenNamesIn(folder);
      const chosen = taken.has(name) ? paths.nextAvailableName(taken, name) : name;
      const target = paths.join(folder, chosen);

      const writes = [];
      await ensureAncestors(target, writes);
      writes.push({ path: target, data: folderNode(target) });
      await nodes.commit(writes);

      return entryFor(folderNode(target));
    },

    async newDocument(parent, name) {
      const folder = paths.normalize(parent);
      const withExtension = paths.isMarkdown(name) ? name : `${name}.md`;
      const taken = await takenNamesIn(folder);
      const chosen = taken.has(withExtension)
        ? paths.nextAvailableName(taken, withExtension)
        : withExtension;
      const target = paths.join(folder, chosen);

      await this.write(target, '');
      return entryFor({ type: 'file', path: target, name: chosen });
    },

    rename(path, name) {
      const source = paths.normalize(path);
      const clean = paths.nameOf(name);
      if (clean === '') throw new ApiError('A name cannot be empty.');
      return relocate(source, paths.join(paths.parentOf(source), clean), 'renamed');
    },

    move(path, parent) {
      const source = paths.normalize(path);
      return relocate(source, paths.join(parent, paths.nameOf(source)), 'moved');
    },

    async duplicate(path) {
      const source = paths.normalize(path);
      const node = await requireNode(source);
      const parent = paths.parentOf(source);
      const copyName = paths.nextAvailableName(await takenNamesIn(parent), node.name);
      const destination = paths.join(parent, copyName);

      const writes = [];
      const renamed = await carryAssets(source, destination, { copy: true }, writes);

      for (const member of await nodes.subtreeOf(source)) {
        const target = paths.rewrite(member.path, source, destination);
        const copied = {
          ...member,
          path: target,
          parent: paths.parentOf(target),
          name: paths.nameOf(target),
          modified: Date.now(),
        };
        if (member.type === 'asset') {
          // Same reasoning as in carryAssets: copies own their own bytes.
          const storagePath = `${target}#${Date.now()}`;
          copied.storagePath = storagePath;
          copied.url = await assets.copy(member.storagePath, storagePath);
        }
        if (renamed && member.path === source && typeof copied.text === 'string') {
          copied.text = rewriteAssetReferences(
            copied.text, renamed.oldFolderName, renamed.newFolderName
          );
        }
        writes.push({ path: target, data: copied });
      }

      await nodes.commit(writes);
      return entryFor({ ...node, path: destination, name: copyName });
    },

    async remove(path) {
      const source = paths.normalize(path);
      const node = await requireNode(source);
      const subtree = await nodes.subtreeOf(source);

      // The assets folder is deliberately left behind, exactly as the local
      // build leaves it: it holds original images the user may have nowhere
      // else, and it is visible in the sidebar to delete separately.
      const storagePaths = subtree
        .filter((member) => member.type === 'asset' && member.storagePath)
        .map((member) => member.storagePath);

      await nodes.commit(subtree.map((member) => ({ path: member.path, remove: true })));
      if (storagePaths.length > 0) await assets.removeAll(storagePaths);

      for (const member of subtree) urlByPath.delete(member.path);
      return { ...entryFor(node), deleted: true };
    },

    async uploadImage(documentPath, file) {
      const document = paths.normalize(documentPath);
      if (document === '') {
        throw new ApiError(
          'Save the document before adding an image.',
          'An image is stored next to the document it belongs to.'
        );
      }
      const extension = paths.extensionOf(file.name);
      if (!IMAGE_EXTENSIONS.includes(extension)) {
        throw new ApiError(
          `That file is not a supported image: ${file.name}`,
          `Supported formats are ${IMAGE_EXTENSIONS.join(', ')}.`
        );
      }
      // `>=`, not `>`: `storage.rules` allows `size < MAX_IMAGE_BYTES`, so a
      // file of exactly the limit is refused by the server. Being one byte
      // more permissive than the rule means the largest accepted file fails
      // with a bare permission error instead of this sentence.
      if (file.size >= MAX_IMAGE_BYTES) {
        throw new ApiError(
          `That image is too large: ${paths.nameOf(file.name)}`,
          `Images must be under ${Math.round(MAX_IMAGE_BYTES / 1024 / 1024)} MB.`
        );
      }

      const folderName = paths.assetsFolderName(document);
      if (folderName === '.assets') {
        throw new ApiError(
          'That document has no name to build an images folder from.',
          'Rename the document and try again.'
        );
      }
      const folder = paths.join(paths.parentOf(document), folderName);
      const taken = await takenNamesIn(folder);
      const fileName = taken.has(file.name)
        ? paths.nextAvailableName(taken, file.name)
        : file.name;
      const target = paths.join(folder, fileName);

      // A collision-proof key, so re-uploading after a delete cannot land on a
      // path Storage still has bytes at.
      const storagePath = `${target}#${Date.now()}`;
      const contentType = imageTypeFor(file, extension);
      const url = await assets.upload(storagePath, file, contentType);

      const writes = [];
      await ensureAncestors(target, writes);
      const existingFolder = await nodes.read(folder);
      if (existingFolder && existingFolder.type !== 'folder') {
        throw new ApiError(`A document is in the way of the images folder: ${folderName}`);
      }
      if (!existingFolder) writes.push({ path: folder, data: folderNode(folder) });
      writes.push({
        path: target,
        data: {
          type: 'asset',
          path: target,
          parent: folder,
          name: fileName,
          storagePath,
          url,
          contentType,
          size: file.size,
          modified: Date.now(),
        },
      });
      await nodes.commit(writes);
      urlByPath.set(target, url);

      const relativePath =
        `${paths.encodeComponent(folderName)}/${paths.encodeComponent(fileName)}`;
      return {
        relativePath,
        markdownReference: paths.markdownImageReference(paths.stemOf(file.name), relativePath),
        fileName,
        path: target,
      };
    },

    /** Synchronous by contract; `read` primes the cache. */
    imageURL(workspacePath) {
      return urlByPath.get(paths.normalize(workspacePath)) ?? null;
    },

    /**
     * WC-1: one folder, watched. The listener is handed the same payload
     * `tree()` returns, so a caller can treat a push exactly like a fetch.
     *
     * The query is `where('parent', '==', folder)` — the same shape `tree()`
     * already issues, so watching a folder costs no more than listing it once
     * and then costs nothing again until something actually changes.
     */
    watchFolder(path, listener) {
      const folder = paths.normalize(path);
      return nodes.watchChildren(folder, (rows) => {
        listener({
          path: folder,
          entries: rows.map(entryFor).sort(paths.compareEntries),
          ancestors: paths.ancestorsOf(folder, workspaceName),
        });
      });
    },

    /**
     * WC-2: one document, watched. The listener receives the payload `read()`
     * returns, or `null` once the document no longer exists.
     *
     * Asset URLs are refreshed from the node as they arrive, so an image added
     * on another device resolves here without a reload. A folder or a
     * non-Markdown file at this path reports `null` rather than throwing:
     * a watcher has no call stack to fail into, and "there is nothing here to
     * show you" is the honest answer in both cases.
     */
    watchDocument(path, listener) {
      const target = paths.normalize(path);
      return nodes.watchNode(target, (node) => {
        if (!node || node.type === 'folder' || !paths.isMarkdown(node.name)) {
          listener(null);
          return;
        }
        const text = node.text ?? '';
        listener({
          path: node.path,
          name: node.name,
          text,
          hasByteOrderMark: Boolean(node.hasByteOrderMark),
          modified: node.modified ?? 0,
          size: new TextEncoder().encode(text).length,
        });
      });
    },

    /**
     * WC-3: the `<stem>.assets` folder beside a document, watched, so an image
     * added on another device can be displayed rather than showing as missing.
     * Only the URL cache is updated; the listener decides whether to re-render.
     */
    watchAssets(documentPath, listener) {
      const target = paths.normalize(documentPath);
      const assetFolder = paths.join(
        paths.parentOf(target),
        paths.assetsFolderName(target)
      );
      return nodes.watchChildren(assetFolder, (rows) => {
        let changed = false;
        for (const asset of rows) {
          if (asset.type !== 'asset' || !asset.url) continue;
          if (urlByPath.get(asset.path) !== asset.url) {
            urlByPath.set(asset.path, asset.url);
            changed = true;
          }
        }
        if (changed) listener();
      });
    },
  };
}
