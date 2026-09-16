// Mapping between a contenteditable subtree and flat character offsets.
//
// Both editing surfaces are contenteditable, and every piece of logic ported
// from the macOS app speaks in `{ location, length }` offsets into a plain
// string. This module is the only place that knows how a DOM tree corresponds
// to that string, which keeps the offset arithmetic in one testable place
// instead of spread through the editors.
//
// The layout contract both surfaces honor:
//   root > block elements, each holding text nodes and inline elements
// The text is the block texts joined with "\n". An empty block contributes an
// empty string, and a `<br>` used to keep an empty block selectable
// contributes nothing.

import { makeRange } from './core/range.js';

const BLOCK_SELECTOR = ':scope > *';

/** Blocks in order. Anything not an element is ignored. */
export function blocksOf(root) {
  return Array.from(root.querySelectorAll(BLOCK_SELECTOR));
}

/** Text of one block, treating a lone `<br>` placeholder as empty. */
function blockText(block) {
  if (block.childNodes.length === 1 && block.firstChild.nodeName === 'BR') {
    return '';
  }
  let text = '';
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  let node = walker.nextNode();
  while (node) {
    text += node.nodeValue;
    node = walker.nextNode();
  }
  return text;
}

export { blockText as textOfBlock };

/** The block `node` sits in, or null when it is not inside one. */
export function blockContaining(root, node) {
  let current = node;
  while (current !== null && current.parentNode !== root) current = current.parentNode;
  return current instanceof Element ? current : null;
}

/**
 * Which block this is, without counting from the beginning.
 *
 * The children are in document order, so the DOM can answer "before or after"
 * and the search halves each time. Counting instead would make every caret
 * move cost a walk of the document.
 */
export function blockIndexOf(root, block) {
  const children = root.childNodes;
  let low = 0;
  let high = children.length - 1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    const other = children[middle];
    if (other === block) return middle;
    const where = other.compareDocumentPosition(block);
    if (where & Node.DOCUMENT_POSITION_FOLLOWING) low = middle + 1;
    else high = middle - 1;
  }
  return -1;
}

/** The plain text the DOM represents. */
export function readPlainText(root) {
  return blocksOf(root).map(blockText).join('\n');
}

/**
 * Character offset of a DOM position.
 *
 * `node` may be a text node or an element; for an element, `offset` counts
 * child nodes, which is what the Selection API reports at block boundaries.
 *
 * `layout` is the render model when the DOM is known to agree with it, which
 * turns finding the block's own offset into a lookup instead of a walk. It is
 * only ever an accelerator: without it the answer is measured.
 */
export function offsetForPosition(root, node, offset, layout = null) {
  if (!root.contains(node) && node !== root) return 0;

  if (layout !== null && node !== root && layout.blockCount === root.childNodes.length) {
    const block = blockContaining(root, node);
    if (block !== null) {
      const index = blockIndexOf(root, block);
      if (index !== -1 && index < layout.blockCount) {
        const within =
          block === node
            ? textLengthOfChildrenBefore(block, offset)
            : offsetWithinBlock(block, node, offset);
        return layout.blockRenderedStart(index) + within;
      }
    }
  }

  const blocks = blocksOf(root);
  let total = 0;

  for (let index = 0; index < blocks.length; index += 1) {
    const block = blocks[index];
    if (index > 0) total += 1; // the newline joining this block to the previous

    if (block === node) {
      return total + textLengthOfChildrenBefore(block, offset);
    }
    if (block.contains(node)) {
      return total + offsetWithinBlock(block, node, offset);
    }
    total += blockText(block).length;
  }

  // A position on the root itself, typically when the editor is empty.
  if (node === root) {
    const before = blocks.slice(0, offset);
    return before.reduce(
      (sum, block, index) => sum + (index > 0 ? 1 : 0) + blockText(block).length,
      0
    );
  }

  return total;
}

function textLengthOfChildrenBefore(block, childIndex) {
  let length = 0;
  for (let index = 0; index < childIndex && index < block.childNodes.length; index += 1) {
    length += textLengthOf(block.childNodes[index]);
  }
  return length;
}

function textLengthOf(node) {
  if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.length;
  if (node.nodeName === 'BR') return 0;
  return node.textContent.length;
}

function offsetWithinBlock(block, node, offset) {
  if (node.nodeType === Node.ELEMENT_NODE) {
    let length = textLengthOfChildrenBefore(node, offset);
    let current = node;
    while (current !== block) {
      length += textLengthOfPrecedingSiblings(current);
      current = current.parentNode;
    }
    return length;
  }

  let length = offset;
  let current = node;
  while (current !== block) {
    length += textLengthOfPrecedingSiblings(current);
    current = current.parentNode;
  }
  return length;
}

function textLengthOfPrecedingSiblings(node) {
  let length = 0;
  let sibling = node.previousSibling;
  while (sibling) {
    length += textLengthOf(sibling);
    sibling = sibling.previousSibling;
  }
  return length;
}

/**
 * DOM position for a character offset.
 *
 * @returns {{ node: Node, offset: number } | null}
 */
export function positionForOffset(root, target, layout = null) {
  if (layout !== null && layout.blockCount > 0 && layout.blockCount === root.childNodes.length) {
    const index = blockCovering(layout, Math.max(0, target));
    const block = root.childNodes[index];
    if (block instanceof Element) {
      return positionWithinBlock(block, Math.max(0, target) - layout.blockRenderedStart(index));
    }
  }

  const blocks = blocksOf(root);
  if (blocks.length === 0) return { node: root, offset: 0 };

  let remaining = Math.max(0, target);

  for (let index = 0; index < blocks.length; index += 1) {
    const block = blocks[index];
    if (index > 0) {
      if (remaining === 0) {
        // Exactly on the newline: prefer the end of the previous block so the
        // caret renders where the user expects rather than jumping a line.
        return endPositionOf(blocks[index - 1]);
      }
      remaining -= 1;
    }

    const length = blockText(block).length;
    if (remaining <= length) {
      return positionWithinBlock(block, remaining);
    }
    remaining -= length;
  }

  return endPositionOf(blocks[blocks.length - 1]);
}

/**
 * First block whose text reaches `target`.
 *
 * The end of one block and the start of the next are the same offset, and the
 * earlier block wins — a caret on a line break belongs to the line it ends,
 * not the one it begins.
 */
function blockCovering(layout, target) {
  let low = 0;
  let high = layout.blockCount - 1;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (layout.blockRenderedEnd(middle) >= target) high = middle;
    else low = middle + 1;
  }
  return low;
}

function positionWithinBlock(block, target) {
  let remaining = target;
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  let node = walker.nextNode();

  while (node) {
    const length = node.nodeValue.length;
    if (remaining <= length) {
      return { node, offset: remaining };
    }
    remaining -= length;
    node = walker.nextNode();
  }

  return { node: block, offset: block.childNodes.length };
}

function endPositionOf(block) {
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  let last = null;
  let node = walker.nextNode();
  while (node) {
    last = node;
    node = walker.nextNode();
  }
  return last
    ? { node: last, offset: last.nodeValue.length }
    : { node: block, offset: block.childNodes.length };
}

/** Current selection as an offset range, or null when it is elsewhere. */
export function selectionRange(root, layout = null) {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return null;

  const range = selection.getRangeAt(0);
  if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) {
    return null;
  }

  const start = offsetForPosition(root, range.startContainer, range.startOffset, layout);
  const end = offsetForPosition(root, range.endContainer, range.endOffset, layout);
  return makeRange(Math.min(start, end), Math.abs(end - start));
}

/** Places the selection at an offset range. */
export function setSelectionRange(root, range, layout = null) {
  const start = positionForOffset(root, range.location, layout);
  const end = positionForOffset(root, range.location + range.length, layout);
  if (!start || !end) return;

  const domRange = document.createRange();
  try {
    domRange.setStart(start.node, start.offset);
    domRange.setEnd(end.node, end.offset);
  } catch {
    return;
  }

  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(domRange);
}
