// Render model → DOM, for the directly-editable rendered view.
//
// The model gives one block per rendered line, each carrying the spans that
// style it and source ranges for every character. This turns that into block
// elements holding inline elements, preserving the text exactly so
// `readPlainText` returns the model's text character for character — which is
// what lets an edit be diffed and mapped back to Markdown (E-7).
//
// Nothing here interprets Markdown. Anything the parser did not recognize
// arrives as plain text and is emitted as plain text (E-8, M-4).
//
// A redraw touches only the blocks the edit disturbed. The model says which
// those are; everything above and below keeps the elements it already had, so
// typing into a long document costs what typing into a short one costs, and
// the caret, the scroll position and the browser's own idea of the selection
// all stay where they were.

import { maxRange } from '../core/range.js';

/**
 * What each surface was last drawn from.
 *
 * `offsetsValidTo` counts the blocks whose `data-rendered-*` still say where
 * they are. An edit moves every offset below it, and writing them all back
 * would be the walk of the whole document this module exists to avoid — so
 * they are brought up to date only when something is about to read them.
 */
const STATE = new WeakMap();

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
 * Brings `root` into line with `model`.
 *
 * The first draw of a model builds every block. After that the model reports
 * the blocks an edit disturbed and only those are built again, which is the
 * difference between an edit costing what it changed and an edit costing the
 * whole document.
 *
 * @param {HTMLElement} root
 * @param {import('../core/render-model.js').MarkdownRenderModel} model
 * @param {(destination: string) => string|null} resolveImage maps a Markdown
 *   destination to a URL the browser can load, or null to show a placeholder.
 * @returns {{built: number, replaced: number, removed: number, kept: number}}
 *   how much work it took, which is what the tests hold to a bound.
 */
export function renderInto(root, model, resolveImage = () => null) {
  const dirty = model.consumeDirty();
  const state = STATE.get(root);

  if (state === undefined || state.model !== model) {
    return buildEveryBlock(root, model, resolveImage);
  }
  if (dirty === null) {
    return { built: 0, replaced: 0, removed: 0, kept: root.childNodes.length };
  }
  return patchBlocks(root, model, resolveImage, dirty, state);
}

function buildEveryBlock(root, model, resolveImage) {
  const count = model.blockCount;
  // Collected into a fragment rather than spread into `replaceChildren`,
  // because a long document is more elements than an argument list can hold.
  const fragment = document.createDocumentFragment();
  for (let index = 0; index < count; index += 1) {
    fragment.append(buildBlock(model, index, resolveImage));
  }
  root.replaceChildren();
  root.append(fragment);
  STATE.set(root, { model, offsetsValidTo: count });
  return { built: count, replaced: count, removed: 0, kept: 0 };
}

/**
 * Rebuilds the disturbed blocks and leaves the rest alone.
 *
 * The DOM is read as the record of what is on screen rather than a list kept
 * alongside it, because a `contenteditable` surface is edited by the browser
 * too: counting the unchanged tail from the end means a block the browser
 * merged away corrects itself instead of throwing the bookkeeping out.
 */
function patchBlocks(root, model, resolveImage, dirty, state) {
  const children = root.childNodes;
  const oldCount = children.length;
  const newCount = model.blockCount;

  // One block either side, because a fenced run's rounded corners belong to
  // its first and last lines (Y-5) — a neighbour can stop being either.
  const from   = Math.max(0, dirty.from - 1);
  const suffix = Math.max(0, dirty.suffix - 1);
  const oldEnd = Math.max(from, oldCount - suffix);
  const newEnd = Math.max(from, newCount - suffix);

  const anchor = children[oldEnd] ?? null;
  const previous = [];
  for (let index = from; index < oldEnd; index += 1) previous.push(children[index]);

  let built = 0;
  let replaced = 0;
  let kept = 0;
  const reused = new Set();
  const fragment = document.createDocumentFragment();

  for (let index = from; index < newEnd; index += 1) {
    const block = buildBlock(model, index, resolveImage);
    built += 1;
    const existing = previous[index - from];
    // Widening the range costs nothing when the neighbour did not move: an
    // identical block keeps the element it already had, so the caret and the
    // browser's selection never notice the redraw.
    if (existing !== undefined && existing.isEqualNode(block)) {
      reused.add(existing);
      fragment.append(existing);
      kept += 1;
      continue;
    }
    fragment.append(block);
    replaced += 1;
  }

  // Only the ones that were not carried over: appending to the fragment has
  // already taken the reused elements out of the surface.
  for (const block of previous) {
    if (!reused.has(block)) block.remove();
  }
  root.insertBefore(fragment, anchor);

  state.offsetsValidTo = Math.min(state.offsetsValidTo, newEnd);
  return { built, replaced, removed: Math.max(0, previous.length - (newEnd - from)), kept };
}

/**
 * Makes every `data-rendered-*` and picture offset say where it really is.
 *
 * An edit shifts every offset below it, and the only things that read them —
 * carrying a picture to a new paragraph, and selecting one to resize — already
 * measure every block on screen when they run. So the correction is paid then,
 * by whoever needs it, rather than on every keystroke by everybody.
 */
export function ensureBlockOffsets(root) {
  const state = STATE.get(root);
  if (state === undefined) return;
  const { model } = state;
  const count = Math.min(model.blockCount, root.childNodes.length);
  for (let index = state.offsetsValidTo; index < count; index += 1) {
    const block = root.childNodes[index];
    if (!(block instanceof HTMLElement)) continue;
    block.dataset.renderedStart = String(model.blockRenderedStart(index));
    block.dataset.renderedEnd = String(model.blockRenderedEnd(index));
    const images = block.querySelectorAll('.me-image');
    if (images.length === 0) continue;
    const spans = model
      .blockSpans(index)
      .filter((span) => span.style.kind === 'image')
      .sort((a, b) => a.sourceRange.location - b.sourceRange.location);
    for (let at = 0; at < images.length && at < spans.length; at += 1) {
      images[at].dataset.sourceLocation = String(spans[at].sourceRange.location);
      images[at].dataset.sourceLength = String(spans[at].sourceRange.length);
    }
  }
  state.offsetsValidTo = count;
}

/** One rendered line, as an element. */
function buildBlock(model, index, resolveImage) {
  const start = model.blockRenderedStart(index);
  const end = model.blockRenderedEnd(index);
  const spans = model.blockSpans(index);

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
  // Where this line begins in the Markdown. Dragging a picture needs to turn
  // a pointer position into a source offset, and a block is the smallest
  // thing on screen that corresponds to a whole line of the document.
  block.dataset.renderedStart = String(start);
  block.dataset.renderedEnd = String(end);
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
    const inSameFence = (at) =>
      at >= 0 &&
      at < model.blockCount &&
      model.blockRenderedStart(at) >= codeSpan.renderedRange.location &&
      model.blockRenderedStart(at) < maxRange(codeSpan.renderedRange);
    if (!inSameFence(index - 1)) block.classList.add('me-code-block--first');
    if (!inSameFence(index + 1)) block.classList.add('me-code-block--last');
  }

  appendInlineContent(block, model.blockText(index), start, end, spans, resolveImage);
  if (block.childNodes.length === 0) block.append(document.createElement('br'));
  markImageOnlyBlock(block);
  return block;
}

/**
 * Marks a line that holds nothing but one picture, and records how wide that
 * picture is.
 *
 * The page is wider than the column the text is set in, and a picture wider
 * than the column reaches into the margins on both sides — the same rule the
 * Mac and iOS builds follow. The stylesheet does the arithmetic; all it needs
 * from here is the width, and to know that this line is a picture's own line.
 *
 * Only when the picture is alone. A picture sitting in a sentence is part of
 * that sentence's line, and pulling the line out from under the words around
 * it would drag them into the margin too.
 */
function markImageOnlyBlock(block) {
  const images = block.querySelectorAll('.me-image');
  if (images.length !== 1) return;
  // `.me-image` carries the model's placeholder character in a hidden holder,
  // so a line that is only a picture has no text of its own beyond it.
  const withoutImages = [...block.childNodes]
    .filter((node) => !(node instanceof Element && node.classList.contains('me-image')))
    .map((node) => node.textContent ?? '')
    .join('')
    .trim();
  if (withoutImages !== '') return;

  block.classList.add('me-block--image');
  const img = images[0].querySelector('img');
  const width = Number.parseFloat(img?.getAttribute('width') ?? '');
  setBlockImageWidth(block, Number.isFinite(width) ? width : null);
}

/**
 * Tells the stylesheet how wide the picture on this line is, so it can work
 * out how far the line may reach into the page's margins.
 *
 * Exported because a resize has to keep it up to date as the picture is
 * dragged, or the picture grows while the room it is allowed spreads into
 * stays where it was.
 */
export function setBlockImageWidth(block, width) {
  if (!block) return;
  if (width === null || !Number.isFinite(width)) {
    block.style.removeProperty('--me-image-width');
    return;
  }
  block.style.setProperty('--me-image-width', `${Math.round(width)}px`);
}

/**
 * Emits `[start, end)` into `block`, wrapping runs in inline elements.
 *
 * Boundaries are collected from every inline span that touches the line, then
 * each resulting segment is wrapped in the styles covering it. Nesting depth
 * is unbounded in Markdown, so the wrappers are applied outermost-first by
 * span length.
 *
 * `text` is this line's own rendered text and `spans` are the spans this line
 * owns, so both scans are the size of the line. They used to be the whole
 * document's, which made drawing it cost lines × spans.
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
      block.append(buildImage(imageSpan, text.slice(from - start, to - start), resolveImage));
      continue;
    }

    let node = document.createTextNode(text.slice(from - start, to - start));
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
  // Where this image is written in the document. Selecting it to change its
  // size needs the exact span of text to replace, and the rendered text has
  // only one character standing in for the whole reference.
  wrapper.dataset.sourceLocation = String(span.sourceRange.location);
  wrapper.dataset.sourceLength = String(span.sourceRange.length);

  const url = resolveImage(span.style.destination);
  if (url) {
    const img = document.createElement('img');
    img.src = url;
    img.alt = span.style.altText;
    // The size the document asked for. Set as attributes rather than style so
    // an image with only one dimension keeps its shape from the file itself,
    // which is more accurate than any number the document could carry.
    if (span.style.width !== null && span.style.width !== undefined) {
      img.setAttribute('width', String(span.style.width));
    }
    if (span.style.height !== null && span.style.height !== undefined) {
      img.setAttribute('height', String(span.style.height));
    }
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
