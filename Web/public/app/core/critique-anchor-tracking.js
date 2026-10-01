// Port of Shared/Sources/MarkdownEditorCore/CritiqueAnchorTracking.swift.
//
// Keeps a critique's marks on the words they were written about while the
// draft is edited underneath them.
//
// A critique is anchored once, by finding each quoted passage in the text and
// remembering where it was. Every keystroke after that moves the words around
// those offsets, and an offset that is not maintained stops describing the
// passage it was found in: the mark slides off the sentence, or swallows
// whatever is typed next to it.
//
// The rules below are about the second failure. The obvious implementation --
// grow the range by whatever was inserted inside it -- is right in the middle
// of a passage and wrong at its edges, because "inside" includes both
// boundaries. Typing a new sentence immediately after a marked one then drags
// the mark over the new sentence, which nobody asked it to comment on.

import { makeRange } from './range.js';

/** Where a marked passage ends up after an edit, or null if the edit took it away. */
export function adjustAnchor(range, edit) {
  const start = range.location;
  const end = range.location + range.length;
  const delta = edit.inserted - edit.removed;
  const removedEnd = edit.location + edit.removed;

  // Wholly after the passage: nothing about it moved. This is also the
  // boundary case that matters most -- an edit *at* the end is after it, so
  // typing a new sentence onto the end of a marked one leaves the mark on the
  // sentence that was criticised.
  if (edit.location >= end) return range;

  // Wholly before it: the passage keeps its length and slides. An insertion
  // exactly at the start counts as before, so typing in front of a marked
  // sentence pushes the mark along rather than stretching it backwards over
  // the new words.
  if (removedEnd <= start) {
    const moved = start + delta;
    if (moved < 0) return null;
    return makeRange(moved, range.length);
  }

  // A line break put inside the passage ends it there. What follows is a new
  // paragraph, and a critique of one paragraph should not reach into the next.
  //
  // Checked before the insert/replace split, not inside it: typing a return
  // between two words replaces the space between them, so it arrives here as a
  // one-character replacement rather than as a pure insertion.
  if (edit.insertedBreaksLine && edit.location > start && edit.location < end) {
    return makeRange(start, edit.location - start);
  }

  // A pure insertion strictly inside. The words either side are still the
  // passage, so it grows.
  if (edit.removed === 0) {
    return makeRange(start, range.length + edit.inserted);
  }

  // Otherwise the edit removed something the passage overlapped. What is left
  // of it is whatever survived on either side, joined by however much was put
  // back in between.
  const keptBefore = Math.max(0, Math.min(end, edit.location) - start);
  const keptAfter = Math.max(0, end - Math.max(start, removedEnd));
  const insertedInside = edit.location >= start ? edit.inserted : 0;
  const length = keptBefore + insertedInside + keptAfter;
  if (length <= 0) return null;
  const newStart = edit.location < start ? edit.location + edit.inserted : start;
  return makeRange(Math.max(0, newStart), length);
}

/**
 * The single replacement that turns `oldText` into `newText`.
 *
 * Derived rather than observed, because what moved the marks is the
 * *document* changing, whoever changed it -- a reload from the server has to
 * move them too, not only typing.
 *
 * A common prefix and suffix is not a real diff and does not need to be: for
 * one keystroke, one paste or one deletion it is exactly right, and those are
 * what happens between two consecutive looks at the text.
 */
export function editBetween(oldText, newText) {
  if (oldText === newText) return null;

  let prefix = 0;
  while (prefix < oldText.length && prefix < newText.length
    && oldText.charCodeAt(prefix) === newText.charCodeAt(prefix)) {
    prefix += 1;
  }
  let suffix = 0;
  while (suffix < oldText.length - prefix
    && suffix < newText.length - prefix
    && oldText.charCodeAt(oldText.length - 1 - suffix)
      === newText.charCodeAt(newText.length - 1 - suffix)) {
    suffix += 1;
  }

  const removed = oldText.length - prefix - suffix;
  const inserted = newText.length - prefix - suffix;
  const insertedText = newText.slice(prefix, prefix + inserted);
  return {
    location: prefix,
    removed,
    inserted,
    insertedBreaksLine: insertedText.includes('\n') || insertedText.includes('\r'),
  };
}

/** Moves every anchored range onto the new text, dropping any the edit removed. */
export function trackItems(items, oldText, newText) {
  const edit = editBetween(oldText, newText);
  if (edit === null) return items;
  return items.map((item) => {
    if (!item.range) return item;
    return { ...item, range: adjustAnchor(item.range, edit) };
  });
}
