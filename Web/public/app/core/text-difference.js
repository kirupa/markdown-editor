// Port of macOS/Sources/MarkdownEditorCore/MarkdownTextDifference.swift.
//
// Rewriting the whole document on every keystroke would reset scroll position
// and selection and make undo useless, so an edit is reduced to the smallest
// replacement that explains it (PRD E-7).

import { clampRange, makeRange, maxRange, substringWithRange } from './range.js';

/**
 * @typedef {{ range: import('./range.js').Range, replacement: string }} TextReplacement
 */

/**
 * Smallest replacement turning `oldText` into `newText`.
 *
 * `requestedRange` is the range the editing surface says it changed. When the
 * text outside it is genuinely untouched that answer is taken as-is, which
 * keeps a plain keystroke O(1). Otherwise the common prefix and suffix are
 * measured directly — the fallback that matters when a rendered-view edit
 * spans more source than the surface reported.
 *
 * @returns {TextReplacement}
 */
export function textReplacement(oldText, newText, requestedRange) {
  const oldRange = clampRange(requestedRange, oldText.length);
  const prefixLength = oldRange.location;
  const suffixLength = oldText.length - maxRange(oldRange);

  if (newText.length >= prefixLength + suffixLength) {
    const oldPrefix = oldText.slice(0, prefixLength);
    const newPrefix = newText.slice(0, prefixLength);
    const oldSuffix = oldText.slice(oldText.length - suffixLength);
    const newSuffix = newText.slice(newText.length - suffixLength);

    if (oldPrefix === newPrefix && oldSuffix === newSuffix) {
      return {
        range: oldRange,
        replacement: substringWithRange(
          newText,
          makeRange(prefixLength, newText.length - prefixLength - suffixLength)
        ),
      };
    }
  }

  let sharedPrefixLength = 0;
  const sharedLength = Math.min(oldText.length, newText.length);
  while (
    sharedPrefixLength < sharedLength &&
    oldText.charCodeAt(sharedPrefixLength) === newText.charCodeAt(sharedPrefixLength)
  ) {
    sharedPrefixLength += 1;
  }

  let sharedSuffixLength = 0;
  while (
    sharedSuffixLength < oldText.length - sharedPrefixLength &&
    sharedSuffixLength < newText.length - sharedPrefixLength &&
    oldText.charCodeAt(oldText.length - sharedSuffixLength - 1) ===
      newText.charCodeAt(newText.length - sharedSuffixLength - 1)
  ) {
    sharedSuffixLength += 1;
  }

  return {
    range: makeRange(
      sharedPrefixLength,
      oldText.length - sharedPrefixLength - sharedSuffixLength
    ),
    replacement: substringWithRange(
      newText,
      makeRange(
        sharedPrefixLength,
        newText.length - sharedPrefixLength - sharedSuffixLength
      )
    ),
  };
}
