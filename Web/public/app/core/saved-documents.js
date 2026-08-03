// Documents kept for later (PRD WB-*).
//
// The recents list is a history: it reorders itself, ages entries out, and
// forgets. That makes it the wrong place to put a document you want to come
// back to, because using the editor normally is enough to lose it. This is a
// separate, explicit list — nothing enters or leaves it except by asking.
//
// Like recents, entries are workspace-relative paths, so the list survives the
// workspace being moved or served from a different machine. Unlike recents,
// the order is the order they were added, newest first, and there is no cap:
// a list the user curates by hand should not throw anything away behind their
// back.

import { isMarkdownPath, standardizePath } from './recent-documents.js';

export { isMarkdownPath, standardizePath };

/**
 * Removes duplicates and anything that is not a Markdown path, preserving the
 * first spelling of each. Applied on read as well as write, so a list hand-
 * edited in localStorage cannot put the UI into a state it cannot represent.
 */
export function normalized(paths) {
  const seen = new Set();
  const result = [];

  for (const path of paths ?? []) {
    const standardized = standardizePath(path);
    if (standardized === '' || !isMarkdownPath(standardized) || seen.has(standardized)) {
      continue;
    }
    seen.add(standardized);
    result.push(standardized);
  }

  return result;
}

/** True when `path` is in `paths`, comparing standardized forms. */
export function contains(path, paths) {
  const wanted = standardizePath(path);
  if (wanted === '') return false;
  return paths.some((candidate) => standardizePath(candidate) === wanted);
}

/**
 * Adds `path` to the front. Adding something already saved is a no-op rather
 * than a reorder — the checkbox is a state, so ticking an already-ticked box
 * must not move the entry out from under whoever is looking at the list.
 */
export function adding(path, paths) {
  const standardized = standardizePath(path);
  if (standardized === '' || !isMarkdownPath(standardized)) return normalized(paths);
  if (contains(standardized, paths)) return normalized(paths);
  return normalized([standardized, ...paths]);
}

/** Removes every occurrence of `path`. */
export function removing(path, paths) {
  const unwanted = standardizePath(path);
  return normalized(paths).filter((candidate) => candidate !== unwanted);
}

/** Adds when absent, removes when present — what the checkbox does. */
export function toggling(path, paths) {
  return contains(path, paths) ? removing(path, paths) : adding(path, paths);
}

/**
 * Follows a document that was renamed or moved.
 *
 * Without this, reorganizing the workspace would quietly empty the list: the
 * old path stops resolving and the entry becomes a dead link the user has to
 * notice and clean up themselves.
 */
export function relocating(fromPath, toPath, paths) {
  if (!contains(fromPath, paths)) return normalized(paths);

  const from = standardizePath(fromPath);
  const to = standardizePath(toPath);
  if (to === '' || !isMarkdownPath(to)) return removing(from, paths);

  // Replaced in place rather than removed and re-added, so a rename does not
  // jump the document to the top of a list the user arranged.
  const replaced = normalized(paths).map((candidate) => (candidate === from ? to : candidate));
  return normalized(replaced);
}

/**
 * Drops everything inside `folderPath`, and the folder itself if it is somehow
 * listed. Used when a folder is deleted, where the documents underneath it
 * are gone without ever being named.
 */
export function removingUnder(folderPath, paths) {
  const folder = standardizePath(folderPath);
  if (folder === '') return normalized(paths);

  return normalized(paths).filter(
    (candidate) => candidate !== folder && !candidate.startsWith(`${folder}/`)
  );
}
