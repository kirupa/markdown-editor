// Path arithmetic for the cloud workspace.
//
// The local build gets all of this from the filesystem: the server resolves a
// path, `scandir` lists a folder, and `rename` moves a subtree. Firestore has
// no filesystem, so a document's place in the tree is just a string field, and
// every one of those operations becomes string work that has to produce the
// *same* answers the PHP side does — otherwise the two storage modes would
// disagree about what a name collision is, or how a folder sorts.
//
// Everything here is pure, so it is all directly testable, which is most of
// why it lives apart from the backend that calls it.

/** Characters the local build percent-encodes in an image reference (I-9). */
const UNRESERVED = /[^A-Za-z0-9\-._~]/g;

export const MARKDOWN_EXTENSIONS = ['md', 'markdown'];

/**
 * A workspace-relative path with no leading, trailing, or doubled separators.
 *
 * Refuses `..` rather than resolving it. There is no directory to escape from
 * in Firestore, but a stored path containing `..` would still make two
 * different strings name the same document, and every uniqueness guarantee
 * here rests on the path being the identity.
 */
export function normalize(path) {
  const parts = String(path ?? '')
    .replace(/\\/g, '/')
    .split('/')
    .filter((part) => part !== '' && part !== '.');

  if (parts.some((part) => part === '..')) {
    throw new Error('A path cannot contain "..".');
  }
  return parts.join('/');
}

export function nameOf(path) {
  const normalized = normalize(path);
  const cut = normalized.lastIndexOf('/');
  return cut === -1 ? normalized : normalized.slice(cut + 1);
}

export function parentOf(path) {
  const normalized = normalize(path);
  const cut = normalized.lastIndexOf('/');
  return cut === -1 ? '' : normalized.slice(0, cut);
}

export function join(parent, name) {
  const left = normalize(parent);
  const right = normalize(name);
  if (!right) return left;
  return left ? `${left}/${right}` : right;
}

/**
 * The part before the final dot, matching PHP's `PATHINFO_FILENAME`.
 *
 * PHP splits on the last dot wherever it is, so the stem of `.gitignore` is
 * empty and its extension is `gitignore`. That looks wrong and is worth
 * keeping anyway: `assetsFolderName` depends on it, and the local build
 * already refuses the `.assets` folder that falls out of it.
 */
export function stemOf(name) {
  const base = nameOf(name);
  const cut = base.lastIndexOf('.');
  return cut === -1 ? base : base.slice(0, cut);
}

/** The part after the final dot, lowercased. Empty when there is no dot. */
export function extensionOf(name) {
  const base = nameOf(name);
  const cut = base.lastIndexOf('.');
  return cut === -1 ? '' : base.slice(cut + 1).toLowerCase();
}

export function isMarkdown(name) {
  return MARKDOWN_EXTENSIONS.includes(extensionOf(name));
}

/** `<document-stem>.assets`, the same convention the local build uses (I-1). */
export function assetsFolderName(documentPath) {
  return `${stemOf(documentPath)}.assets`;
}

/**
 * Every ancestor of `path`, outermost first, for the explorer's path dropdown.
 *
 * Mirrors FileTree::ancestors — the root is included and named after the
 * workspace, and nothing above it exists.
 */
export function ancestorsOf(path, rootName) {
  const trail = [{ name: rootName, path: '' }];
  let accumulated = '';
  for (const part of normalize(path).split('/').filter(Boolean)) {
    accumulated = accumulated ? `${accumulated}/${part}` : part;
    trail.push({ name: part, path: accumulated });
  }
  return trail;
}

/**
 * Whether `path` is inside `folder`.
 *
 * The `/` matters: without it `Notes` would claim `Notes archive.md`, and a
 * folder would take a similarly named sibling with it when deleted.
 */
export function isDescendantOf(path, folder) {
  const child = normalize(path);
  const parent = normalize(folder);
  if (parent === '') return child !== '';
  return child.startsWith(`${parent}/`);
}

/** Repoints `path` from under `from` to under `to`, including `path === from`. */
export function rewrite(path, from, to) {
  const target = normalize(path);
  const source = normalize(from);
  if (target === source) return normalize(to);
  if (!isDescendantOf(target, source)) return target;
  const tail = source === '' ? target : target.slice(source.length + 1);
  return join(to, tail);
}

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });

/**
 * Explorer order: expandable folders first, then natural case-insensitive
 * order so "Folder 2" precedes "Folder 10" (X-6, X-7, X-8).
 *
 * `Intl.Collator` with `numeric` is the JavaScript spelling of PHP's
 * `strnatcasecmp`, which is what the local build sorts with.
 */
export function compareEntries(left, right) {
  if (left.isExpandable !== right.isExpandable) return left.isExpandable ? -1 : 1;
  return collator.compare(left.name, right.name);
}

/**
 * The first free name of the form `stem-2.ext`, matching FileManager's
 * `nextAvailable` so a duplicate is named identically in both storage modes.
 *
 * @param {Set<string>|Array<string>} taken names already used in the folder
 */
export function nextAvailableName(taken, name) {
  const used = taken instanceof Set ? taken : new Set(taken);
  const base = nameOf(name);
  const stem = stemOf(base);
  const extension = base.slice(stem.length); // keeps the dot, and its case

  for (let suffix = 2; suffix < 10000; suffix += 1) {
    const candidate = `${stem}-${suffix}${extension}`;
    if (!used.has(candidate)) return candidate;
  }

  throw new Error(`There are too many copies of ${base} already.`);
}

/** Percent-encodes one path component exactly as ImageImporter::encodeComponent does. */
export function encodeComponent(component) {
  const bytes = new TextEncoder();
  return String(component).replace(UNRESERVED, (character) => {
    let out = '';
    for (const byte of bytes.encode(character)) {
      out += `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
    }
    return out;
  });
}

/** `![alt](path)` with the alt text escaped so a filename cannot break it (I-10). */
export function markdownImageReference(altText, relativePath) {
  const escaped = String(altText)
    .replace(/\\/g, '\\\\')
    .replace(/\[/g, '\\[')
    .replace(/\]/g, '\\]');
  return `![${escaped}](${relativePath})`;
}

/**
 * A Firestore document ID for a workspace path.
 *
 * The path is the identity of a node, so making it the ID means uniqueness is
 * enforced by the database rather than by a query the client has to remember
 * to run, and every read by path is a single get. Firestore IDs cannot contain
 * a slash, and `encodeURIComponent` both removes it and leaves the ID readable
 * in the console, which matters when eyeballing it is the only way to inspect
 * this data.
 */
export function documentId(path) {
  const normalized = normalize(path);
  if (normalized === '') throw new Error('The workspace root is not a document.');
  return encodeURIComponent(normalized);
}

export function pathFromDocumentId(id) {
  return decodeURIComponent(id);
}

/**
 * Every ancestor folder of `path`, outermost first, so they can be created
 * before a document that assumes they exist.
 */
export function ancestorFolders(path) {
  const parts = normalize(path).split('/').filter(Boolean);
  parts.pop();
  const folders = [];
  let accumulated = '';
  for (const part of parts) {
    accumulated = accumulated ? `${accumulated}/${part}` : part;
    folders.push(accumulated);
  }
  return folders;
}
