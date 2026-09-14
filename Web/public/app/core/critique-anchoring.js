// Port of Shared/Sources/MarkdownEditorCore/CritiqueAnchoring.swift.
//
// Where each finding's quoted passage actually sits in the document.
//
// A critique names a passage by quoting it. Highlighting that passage means
// finding the quote again in the text -- which sounds like one `indexOf` and
// is not, for three reasons this handles:
//
//  * A model re-types a quote as often as it copies one. Curly quotes become
//    straight, a line break inside a sentence becomes a space, a run of spaces
//    collapses. The passage is still there; the bytes are not.
//  * A short quote can occur several times. The finding says which one it
//    means -- "paragraph 3" -- and using that beats highlighting the first hit.
//  * Sometimes the quote is simply not in the draft, because the model
//    paraphrased. That has to be visible rather than silently anchored to
//    something that merely looks similar.
//
// WX-2 applies throughout: Swift's NSString offsets and JavaScript string
// indices are both UTF-16 code units, so every range in the Swift source is
// already correct here with no conversion.

import { intersectionRange, makeRange, maxRange, lineBounds } from './range.js';

/**
 * Anchors every finding, keeping the order they arrived in.
 *
 * Two findings can quote the same words. Each should get its own occurrence
 * where the text offers one, so the rail does not stack two cards on one
 * highlight while an identical passage sits unmarked.
 */
export function anchorFindings(findings, text) {
  const claimed = [];
  return findings.map((finding) => {
    const range = rangeForFinding(finding, text, claimed);
    if (range) claimed.push(range);
    return { findingID: finding.id, range };
  });
}

/** Where one finding's quote sits, preferring an unclaimed occurrence. */
export function rangeForFinding(finding, text, claimed = []) {
  const quote = String(finding.quote ?? '').trim();
  if (quote === '') return null;

  const candidates = occurrences(quote, text);
  if (candidates.length === 0) return null;

  const unclaimed = candidates.filter(
    (candidate) => !claimed.some((taken) => intersectionRange(taken, candidate).length > 0)
  );
  const usable = unclaimed.length > 0 ? unclaimed : candidates;
  return choose(usable, String(finding.location ?? ''), text);
}

// MARK: - Finding the words

/**
 * Every place `quote` appears, exactly or allowing for retyping.
 *
 * The exact pass runs first and wins outright when it finds anything: a
 * verbatim match is the strongest evidence available, and falling through to a
 * looser comparison after one succeeds could only make things worse.
 */
export function occurrences(quote, text) {
  const exact = exactOccurrences(quote, text);
  if (exact.length > 0) return exact;
  return relaxedOccurrences(quote, text);
}

function exactOccurrences(quote, text) {
  const found = [];
  let searchFrom = 0;
  while (searchFrom < text.length) {
    const hit = text.indexOf(quote, searchFrom);
    if (hit < 0) break;
    found.push(makeRange(hit, quote.length));
    searchFrom = hit + Math.max(1, quote.length);
  }
  return found;
}

/**
 * Matches the quote against the text ignoring how whitespace and quote marks
 * were typed, then reports the range in the *original* text.
 *
 * Done by folding both sides to a canonical form while keeping, for every
 * folded character, the offset it came from. The match is performed on the
 * folded text and the answer is translated back, so the highlight lands on
 * real characters rather than on an approximation of them.
 */
function relaxedOccurrences(quote, text) {
  const foldedText = fold(text);
  const foldedQuote = fold(quote);
  if (foldedQuote.value === '') return [];

  const haystack = foldedText.value;
  const needle = foldedQuote.value;
  const found = [];
  let searchFrom = 0;
  while (searchFrom < haystack.length) {
    const hit = haystack.indexOf(needle, searchFrom);
    if (hit < 0 || needle.length === 0) break;
    const startOffset = foldedText.offsets[hit];
    const lastOffset = foldedText.offsets[hit + needle.length - 1];
    found.push(makeRange(startOffset, lastOffset - startOffset + 1));
    searchFrom = hit + 1;
  }
  return found;
}

const WHITESPACE = /\s/;

/**
 * A canonical form, plus where each of its characters came from.
 *
 * Collapses whitespace runs to one space and normalises the punctuation a
 * model is most likely to re-type: curly quotes, dashes, and ellipses.
 *
 * `offsets[i]` is the UTF-16 offset in the original text that `value[i]` came
 * from.
 */
export function fold(text) {
  const source = String(text ?? '');
  let value = '';
  const offsets = [];
  let lastWasSpace = false;

  for (let offset = 0; offset < source.length; offset += 1) {
    const character = source[offset];
    if (WHITESPACE.test(character)) {
      // A run of any whitespace -- including the newline inside a wrapped
      // sentence -- becomes a single space, because that is how a model
      // reproduces it.
      if (lastWasSpace) continue;
      value += ' ';
      offsets.push(offset);
      lastWasSpace = true;
      continue;
    }
    lastWasSpace = false;
    value += canonical(character);
    offsets.push(offset);
  }
  return { value, offsets };
}

function canonical(character) {
  switch (character) {
    case '\u2018':
    case '\u2019':
    case '\u201B':
    case '\u2032':
      return "'";
    case '\u201C':
    case '\u201D':
    case '\u201F':
    case '\u2033':
      return '"';
    case '\u2010':
    case '\u2011':
    case '\u2012':
    case '\u2013':
    case '\u2014':
      return '-';
    case '\u00A0':
      return ' ';
    default:
      return character.toLowerCase();
  }
}

// MARK: - Choosing between several matches

/**
 * Picks the occurrence the finding's location points at.
 *
 * The skill writes locations like "Opening, paragraph 2" or "paragraph 4".
 * When a number is there, it is a paragraph index counted from the top of the
 * draft, so the occurrence inside that paragraph is the one meant. With
 * nothing to go on, the first is as good a guess as any -- and better than the
 * last.
 */
export function choose(candidates, location, text) {
  if (candidates.length <= 1) return candidates[0] ?? null;
  const wanted = paragraphNumber(location);
  if (wanted === null) return candidates[0];
  const paragraphs = paragraphRanges(text);
  if (wanted < 1 || wanted > paragraphs.length) return candidates[0];
  const target = paragraphs[wanted - 1];
  return (
    candidates.find((candidate) => intersectionRange(candidate, target).length > 0) ??
    candidates[0]
  );
}

/** The paragraph number named in a location string, if any. */
export function paragraphNumber(location) {
  const lowered = String(location ?? '').toLowerCase();
  const keyword = lowered.indexOf('paragraph');
  if (keyword < 0) return null;
  const after = lowered.slice(keyword + 'paragraph'.length);
  const digits = after.replace(/^\D*/, '').match(/^\d+/);
  return digits === null ? null : Number(digits[0]);
}

/**
 * The non-empty blocks of the draft, in order.
 *
 * Counted the way a reader counts them -- blank-line separated blocks --
 * rather than by newline, so a paragraph that wraps is still one paragraph and
 * the numbers in a critique line up with the text.
 */
export function paragraphRanges(text) {
  const source = String(text ?? '');
  const ranges = [];
  let start = null;
  let blankRunStart = null;

  let index = 0;
  while (index < source.length) {
    const bounds = lineBounds(source, index);
    const lineRange = makeRange(bounds.lineStart, bounds.lineEnd - bounds.lineStart);
    const line = source.slice(lineRange.location, maxRange(lineRange));
    const isBlank = line.trim() === '';
    if (isBlank) {
      if (start !== null && blankRunStart !== null) {
        ranges.push(makeRange(start, blankRunStart - start));
        start = null;
      }
      blankRunStart = null;
    } else {
      if (start === null) start = lineRange.location;
      blankRunStart = maxRange(lineRange);
    }
    index = maxRange(lineRange);
    if (lineRange.length === 0) break;
  }
  if (start !== null) {
    ranges.push(makeRange(start, (blankRunStart ?? source.length) - start));
  }
  return ranges;
}
