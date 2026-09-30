import { intersectionRange, maxRange } from './range.js';
import { renderMarkdown } from './render-model.js';

/**
 * Where a selection sits, as far as Markdown's *inline* syntax is concerned.
 *
 * Markdown is inert inside code. `**bold**` typed into a fenced block or
 * between a code span's backticks is not emphasis — it is four asterisks and a
 * word, and every conforming renderer, including this one, shows it that way.
 * So a formatting command run there cannot do what it was asked to do: the
 * only thing it can produce is literal punctuation in the writer's code.
 *
 * A port of `Shared/Sources/MarkdownEditorCore/MarkdownCodeContext.swift`.
 * Derived from the render model rather than from a scanner of its own, so the
 * commands refuse in exactly the places the reading view draws as code.
 *
 * Four-space indented code is deliberately not here: this renderer does not
 * implement it, an indented line is an ordinary paragraph, and refusing there
 * would stop a command that visibly works. See Contract/README.md.
 */
export const CodeContextKind = Object.freeze({
  /** A paragraph, a heading, a list item, or a block quote. */
  prose: 'prose',
  /** Inside a fenced block, its own fence lines included. */
  codeBlock: 'codeBlock',
  /** Between the backticks of an inline code span. */
  inlineCodeSpan: 'inlineCodeSpan',
});

const PROSE = Object.freeze({ kind: CodeContextKind.prose, sourceRange: null });

/**
 * The context `selection` sits in, within `text`.
 *
 * Pass the live model when there is one — `model.source === text` — and
 * nothing is parsed; otherwise the document is.
 *
 * @param {{ location: number, length: number }} selection
 * @param {string} text
 * @param {import('./render-model.js').MarkdownRenderModel|null} [model]
 * @returns {{ kind: string, sourceRange: ({ location: number, length: number }|null) }}
 */
export function codeContextIn(selection, text, model = null) {
  const rendered = model !== null && model.source === text ? model : renderMarkdown(text);
  return codeContextInModel(selection, rendered);
}

/**
 * The context `selection` sits in, within an already rendered model. This is
 * asked on every caret move.
 *
 * Only the spans at the selection's two ends are read, and the answer is the
 * one the whole document gives. The code a caret is in contains the caret. The
 * code a selection is in overlaps it without lying inside it, and a region that
 * does that holds the selection's first character or its last. A fence covers
 * the line either one is on and a code span never leaves its line, so the
 * model's per-offset lookup holds every candidate — where `model.spans` would
 * build every span in the document.
 *
 * @param {{ location: number, length: number }} selection
 * @param {import('./render-model.js').MarkdownRenderModel} model
 */
export function codeContextInModel(selection, model) {
  let spans = model.spansAtSourceOffset(selection.location);
  // A fence found at the start is already the answer — fences are asked first,
  // and nothing further on precedes it.
  if (selection.length > 0 && firstFence(selection, spans) === null) {
    spans = spans.concat(model.spansAtSourceOffset(maxRange(selection) - 1));
  }
  return contextAmong(selection, spans);
}

/**
 * The same question answered by walking every span in the document. The
 * per-offset reading above is tested against this one.
 *
 * @param {{ location: number, length: number }} selection
 * @param {import('./render-model.js').MarkdownRenderModel} model
 */
export function codeContextAmongAllSpans(selection, model) {
  return contextAmong(selection, model.spans);
}

function contextAmong(selection, spans) {
  // A fenced block is asked first: backticks written inside one are not a code
  // span, and the block is the stronger statement about what the text means.
  const fence = firstFence(selection, spans);
  if (fence !== null) {
    return { kind: CodeContextKind.codeBlock, sourceRange: fence };
  }
  for (const span of spans) {
    if (span.style.kind !== 'inlineCode') continue;
    if (touches(selection, span.sourceRange, false)) {
      return { kind: CodeContextKind.inlineCodeSpan, sourceRange: span.sourceRange };
    }
  }
  return PROSE;
}

function firstFence(selection, spans) {
  for (const span of spans) {
    if (span.style.kind !== 'codeBlock' || !span.includesMarkup) continue;
    if (touches(selection, span.sourceRange, true)) return span.sourceRange;
  }
  return null;
}

/** Whether a context is code of either kind. */
export function isCodeContext(context) {
  return context.kind !== CodeContextKind.prose;
}

/**
 * Whether `selection` is code rather than the prose around it.
 *
 * A selection that *contains* the whole region is prose holding a piece of
 * code — bolding `` `x` `` along with the words either side of it is both
 * legal and useful — so that case is let through. A selection that overlaps
 * the region without containing it is not: it would put one marker inside the
 * code and its partner outside.
 *
 * `startIsInside` is the asymmetry between the two kinds of code. A caret at
 * the first character of a fence line is inside the block, because what gets
 * written there displaces the fence. A caret at the first backtick of a code
 * span is in front of it, and what gets written there lands in the prose.
 */
function touches(selection, region, startIsInside) {
  const lower = startIsInside ? region.location : region.location + 1;
  const upper = maxRange(region);
  if (upper <= lower) return false;

  if (selection.length === 0) {
    return selection.location >= lower && selection.location < upper;
  }
  if (intersectionRange(selection, region).length === 0) return false;
  const containsRegion =
    selection.location <= region.location && upper <= maxRange(selection);
  return !containsRegion;
}
