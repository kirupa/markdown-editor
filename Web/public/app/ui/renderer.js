// Render model → DOM, for the directly-editable rendered view.
//
// The model gives flat rendered text plus spans carrying source ranges. This
// turns that into block elements holding inline elements, preserving the text
// exactly so `readPlainText` returns the model's text character for character
// — which is what lets an edit be diffed and mapped back to Markdown (E-7).
//
// Nothing here interprets Markdown. Anything the parser did not recognize
// arrives as plain text and is emitted as plain text (E-8, M-4).

import { maxRange } from '../core/range.js';

/** Per-line block styling, taken from whichever spans cover the line. */
function blockClassFor(styles) {
  for (const style of styles) {
    if (style.kind === 'heading') return `me-h${style.level}`;
    if (style.kind === 'codeBlock') return 'me-code-block';
    if (style.kind === 'quote') return 'me-quote';
    if (style.kind === 'horizontalRule') return 'me-rule';
    if (
      style.kind === 'bulletedList' ||
      style.kind === 'numberedList' ||
      style.kind === 'taskList'
    ) {
      return 'me-list';
    }
  }
  return null;
}

const INLINE_CLASSES = {
  bold: 'me-bold',
  italic: 'me-italic',
  underline: 'me-underline',
  strikethrough: 'me-strike',
  inlineCode: 'me-code',
  link: 'me-link',
};

/** Spans that style a run of characters rather than a whole line. */
function isInline(style) {
  return Object.prototype.hasOwnProperty.call(INLINE_CLASSES, style.kind);
}

function isBlock(style) {
  return (
    style.kind === 'heading' ||
    style.kind === 'codeBlock' ||
    style.kind === 'quote' ||
    style.kind === 'horizontalRule' ||
    style.kind === 'bulletedList' ||
    style.kind === 'numberedList' ||
    style.kind === 'taskList'
  );
}

/**
 * Builds the rendered DOM into `root`.
 *
 * @param {HTMLElement} root
 * @param {import('../core/render-model.js').MarkdownRenderModel} model
 * @param {(destination: string) => string|null} resolveImage maps a Markdown
 *   destination to a URL the browser can load, or null to show a placeholder.
 */
export function renderInto(root, model, resolveImage = () => null) {
  const { text, spans } = model;
  const blocks = [];

  let lineStart = 0;
  while (lineStart <= text.length) {
    let lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd === -1) lineEnd = text.length;
    blocks.push({ start: lineStart, end: lineEnd });
    if (lineEnd === text.length) break;
    lineStart = lineEnd + 1;
  }

  const elements = blocks.map(({ start, end }, index) => {
    const covering = spans.filter((span) => {
      if (!isBlock(span.style)) return false;
      const from = span.renderedRange.location;
      const to = maxRange(span.renderedRange);
      if (from > start || to < end) return false;
      // A block ends *before* the newline that closes its last line, so an
      // empty line sitting exactly at `to` belongs to whatever follows.
      return start < to || span.renderedRange.length === 0;
    });

    const block = document.createElement('div');
    block.className = 'me-block';
    const blockClass = blockClassFor(covering.map((span) => span.style));
    if (blockClass) block.classList.add(blockClass);

    const codeSpan = covering
      .filter((span) => span.style.kind === 'codeBlock')
      // The model emits both a per-line span and one covering the whole fence.
      // Only the widest one describes the run the rounded rectangle wraps (Y-5).
      .sort((a, b) => b.renderedRange.length - a.renderedRange.length)[0];
    if (codeSpan) {
      // Y-5: the fence renders as one continuous rounded rectangle, so only
      // the first and last lines of a run get rounded corners.
      const previous = blocks[index - 1];
      const next = blocks[index + 1];
      const inSameFence = (line) =>
        line !== undefined &&
        line.start >= codeSpan.renderedRange.location &&
        line.start < maxRange(codeSpan.renderedRange);
      if (!inSameFence(previous)) block.classList.add('me-code-block--first');
      if (!inSameFence(next)) block.classList.add('me-code-block--last');
    }

    appendInlineContent(block, text, start, end, spans, resolveImage);
    if (block.childNodes.length === 0) block.append(document.createElement('br'));
    return block;
  });

  root.replaceChildren(...elements);
}

/**
 * Emits `[start, end)` into `block`, wrapping runs in inline elements.
 *
 * Boundaries are collected from every inline span that touches the line, then
 * each resulting segment is wrapped in the styles covering it. Nesting depth
 * is unbounded in Markdown, so the wrappers are applied outermost-first by
 * span length.
 */
function appendInlineContent(block, text, start, end, spans, resolveImage) {
  const touching = spans.filter(
    (span) =>
      (isInline(span.style) || span.style.kind === 'image') &&
      span.renderedRange.location < end &&
      maxRange(span.renderedRange) > start
  );

  const boundaries = new Set([start, end]);
  for (const span of touching) {
    const from = Math.max(start, span.renderedRange.location);
    const to = Math.min(end, maxRange(span.renderedRange));
    boundaries.add(from);
    boundaries.add(to);
  }

  const points = [...boundaries].sort((a, b) => a - b);

  for (let index = 0; index < points.length - 1; index += 1) {
    const from = points[index];
    const to = points[index + 1];
    if (to <= from) continue;

    const covering = touching
      .filter(
        (span) =>
          span.renderedRange.location <= from && maxRange(span.renderedRange) >= to
      )
      .sort((a, b) => b.renderedRange.length - a.renderedRange.length);

    const imageSpan = covering.find((span) => span.style.kind === 'image');
    if (imageSpan) {
      block.append(buildImage(imageSpan, text.slice(from, to), resolveImage));
      continue;
    }

    let node = document.createTextNode(text.slice(from, to));
    for (const span of covering) {
      const className = INLINE_CLASSES[span.style.kind];
      if (!className) continue;
      const wrapper = document.createElement(
        span.style.kind === 'inlineCode' ? 'code' : 'span'
      );
      wrapper.className = className;
      if (span.style.kind === 'link') wrapper.title = span.style.destination;
      wrapper.append(node);
      node = wrapper;
    }
    block.append(node);
  }
}

/**
 * An image renders as one atomic unit whose text content is still the model's
 * placeholder character, so offsets stay aligned (M-7). `contenteditable=false`
 * keeps the caret from entering it.
 */
function buildImage(span, placeholderText, resolveImage) {
  const wrapper = document.createElement('span');
  wrapper.className = 'me-image';
  wrapper.contentEditable = 'false';
  wrapper.dataset.destination = span.style.destination;

  const url = resolveImage(span.style.destination);
  if (url) {
    const img = document.createElement('img');
    img.src = url;
    img.alt = span.style.altText;
    img.addEventListener('error', () => {
      img.replaceWith(brokenImageLabel(span.style));
    });
    wrapper.append(img);
  } else {
    wrapper.append(brokenImageLabel(span.style));
  }

  // The placeholder text lives in a zero-width holder so the rendered text
  // still contains exactly the characters the model reported.
  const holder = document.createElement('span');
  holder.style.position = 'absolute';
  holder.style.width = '0';
  holder.style.height = '0';
  holder.style.overflow = 'hidden';
  holder.textContent = placeholderText;
  wrapper.append(holder);

  return wrapper;
}

/**
 * The label is drawn from a `data-` attribute through CSS generated content
 * rather than a text node, because everything inside `.me-image` except the
 * placeholder holder must contribute zero characters to the document text.
 */
function brokenImageLabel(style) {
  const label = document.createElement('span');
  label.className = 'me-image--broken';
  label.dataset.label = style.altText || style.destination;
  return label;
}
