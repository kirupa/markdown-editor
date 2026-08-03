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

/** The plain text the DOM represents. */
export function readPlainText(root) {
  return blocksOf(root).map(blockText).join('\n');
}

/**
 * Character offset of a DOM position.
 *
 * `node` may be a text node or an element; for an element, `offset` counts
 * child nodes, which is what the Selection API reports at block boundaries.
 */
export function offsetForPosition(root, node, offset) {
  if (!root.contains(node) && node !== root) return 0;

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
export function positionForOffset(root, target) {
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
export function selectionRange(root) {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return null;

  const range = selection.getRangeAt(0);
  if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) {
    return null;
  }

  const start = offsetForPosition(root, range.startContainer, range.startOffset);
  const end = offsetForPosition(root, range.endContainer, range.endOffset);
  return makeRange(Math.min(start, end), Math.abs(end - start));
}

/** Places the selection at an offset range. */
export function setSelectionRange(root, range) {
  const start = positionForOffset(root, range.location);
  const end = positionForOffset(root, range.location + range.length);
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
