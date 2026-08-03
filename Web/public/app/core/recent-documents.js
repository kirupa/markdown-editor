// Port of macOS/Sources/MarkdownEditorCore/RecentDocumentsCatalog.swift.
//
// Pure list arithmetic behind the welcome screen's recent documents (PRD
// W-13 through W-23). Storage and liveness checks live elsewhere, so the
// ordering, de-duplication, and capping rules stay directly testable.
//
// The macOS app keys entries by absolute filesystem path. The web version
// keys them by workspace-relative path, because that is the only identity a
// browser has for a server-side file — and it is the identity that survives
// the workspace folder being moved or served from a different machine.

/** How many paths are persisted between visits. */
export const STORED_LIMIT = 40;

/** How many entries the welcome screen shows. */
export const DISPLAY_LIMIT = 12;

const MARKDOWN_EXTENSIONS = ['md', 'markdown'];

export function isMarkdownPath(path) {
  const match = /\.([^./\\]+)$/.exec(path ?? '');
  return match !== null && MARKDOWN_EXTENSIONS.includes(match[1].toLowerCase());
}

/**
 * Collapses `a//b`, `./b`, and a leading or trailing slash so the same file
 * reached by two spellings de-duplicates. This stands in for Swift's
 * `standardizedFileURL`; `..` never appears because the server rejects it.
 */
export function standardizePath(path) {
  return String(path ?? '')
    .replace(/\\/g, '/')
    .split('/')
    .filter((component) => component !== '' && component !== '.')
    .join('/');
}

/**
 * Concatenates two most-recent-first lists, keeps the first occurrence of each
 * standardized path, drops anything that is not Markdown, and caps the result.
 */
export function merged(preferred, additional = [], limit = STORED_LIMIT) {
  if (limit <= 0) return [];

  const seen = new Set();
  const result = [];

  for (const path of [...preferred, ...additional]) {
    const standardized = standardizePath(path);
    if (standardized === '' || !isMarkdownPath(standardized) || seen.has(standardized)) {
      continue;
    }
    seen.add(standardized);
    result.push(standardized);
    if (result.length === limit) break;
  }

  return result;
}

/** Moves `path` to the front, removing any earlier occurrence. */
export function promoting(path, paths, limit = STORED_LIMIT) {
  return merged([path], paths, limit);
}

/** Removes every occurrence of `path`, comparing standardized forms. */
export function removing(path, paths) {
  const removed = standardizePath(path);
  return paths.filter((candidate) => standardizePath(candidate) !== removed);
}

/**
 * Display metadata for each path, capped at `limit`.
 *
 * `folderDisplayPath` is the containing folder, or the workspace name for a
 * document at the root — the web equivalent of the macOS build abbreviating
 * the home directory to `~` (W-14), since a workspace-relative path is
 * already as short as it can be.
 *
 * @returns {Array<{path: string, name: string, folderDisplayPath: string}>}
 */
export function entries(paths, workspaceName = 'Workspace', limit = DISPLAY_LIMIT) {
  if (limit <= 0) return [];

  return paths.slice(0, limit).map((path) => {
    const standardized = standardizePath(path);
    const separatorIndex = standardized.lastIndexOf('/');
    return {
      path: standardized,
      name: separatorIndex === -1
        ? standardized
        : standardized.slice(separatorIndex + 1),
      folderDisplayPath: separatorIndex === -1
        ? workspaceName
        : `${workspaceName}/${standardized.slice(0, separatorIndex)}`,
    };
  });
}
