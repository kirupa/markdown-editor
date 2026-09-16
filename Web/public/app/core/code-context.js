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
 * @param {{ location: number, length: number }} selection
 * @param {string} text
 * @returns {{ kind: string, sourceRange: ({ location: number, length: number }|null) }}
 */
export function codeContextIn(selection, text) {
  return codeContextInModel(selection, renderMarkdown(text));
}

/**
 * The context `selection` sits in, within an already rendered model. Callers
 * holding a model should use this: rendering again costs tens of milliseconds
 * on a long document and this is asked on every caret move.
 *
 * @param {{ location: number, length: number }} selection
 * @param {import('./render-model.js').MarkdownRenderModel} model
 */
export function codeContextInModel(selection, model) {
  // A fenced block is asked first: backticks written inside one are not a code
  // span, and the block is the stronger statement about what the text means.
  for (const span of model.spans) {
    if (span.style.kind !== 'codeBlock' || !span.includesMarkup) continue;
    if (touches(selection, span.sourceRange, true)) {
      return { kind: CodeContextKind.codeBlock, sourceRange: span.sourceRange };
    }
  }
  for (const span of model.spans) {
    if (span.style.kind !== 'inlineCode') continue;
    if (touches(selection, span.sourceRange, false)) {
      return { kind: CodeContextKind.inlineCodeSpan, sourceRange: span.sourceRange };
    }
  }
  return PROSE;
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
