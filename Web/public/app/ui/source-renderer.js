// Raw Markdown pane.
//
// Every source marker stays visible (E-18), but headings and fenced code take
// the same sizes the preview uses (E-19). That is what keeps the two halves of
// Split at similar vertical proportions, so scroll sync is meaningful rather
// than approximate.
//
// The classification comes from the render model's spans rather than a second
// scanner, so the two panes can never disagree about what a line is — the same
// rule the macOS `MarkdownSourceStyler` follows, including styling nothing
// else: no colors, no backgrounds, just size and weight.

import { maxRange } from '../core/range.js';

/**
 * Renders `source` as one styled block per line.
 *
 * @param {HTMLElement} root
 * @param {string} source
 * @param {import('../core/render-model.js').MarkdownRenderModel} model
 */
export function renderSourceInto(root, source, model) {
  const headings = [];
  const codeRanges = [];

  for (const span of model.spans) {
    if (span.style.kind === 'heading') {
      headings.push({ location: span.sourceRange.location, level: span.style.level });
    } else if (span.style.kind === 'codeBlock' && span.includesMarkup) {
      codeRanges.push(span.sourceRange);
    }
  }

  const blocks = [];
  let lineStart = 0;

  while (lineStart <= source.length) {
    let lineEnd = source.indexOf('\n', lineStart);
    if (lineEnd === -1) lineEnd = source.length;

    const block = document.createElement('div');
    block.className = 'me-src-line';

    const heading = headings.find(
      (entry) => entry.location >= lineStart && entry.location <= lineEnd
    );
    if (heading) {
      block.classList.add(`me-src-h${heading.level}`);
    } else {
      const fence = codeRanges.find(
        (range) => range.location <= lineStart && maxRange(range) > lineStart
      );
      if (fence) block.classList.add('me-src-code');
    }

    const line = source.slice(lineStart, lineEnd);
    block.append(line === '' ? document.createElement('br') : document.createTextNode(line));
    blocks.push(block);

    if (lineEnd === source.length) break;
    lineStart = lineEnd + 1;
  }

  root.replaceChildren(...blocks);
}
