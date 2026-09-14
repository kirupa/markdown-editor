// Shading the passages a critique points at.
//
// Painted with the CSS Custom Highlight API rather than by wrapping each
// passage in an element. Both surfaces are `contenteditable`, and inserting a
// <mark> into one moves every offset after it, corrupts the mapping the editor
// reads selections through, and arrives in the browser's undo stack as though
// the author had typed it. A highlight paints over the text without touching
// the tree, which is the only version of this that is safe in an editor.
//
// Where the API is missing the cards still work and the rail says so; nothing
// silently half-happens.

import { positionForOffset } from '../dom-text.js';

const NAMES = [
  'me-critique-high',
  'me-critique-medium',
  'me-critique-low',
  'me-critique-selected-high',
  'me-critique-selected-medium',
  'me-critique-selected-low',
];

export function highlightsSupported() {
  return typeof CSS !== 'undefined' && typeof CSS.highlights !== 'undefined'
    && typeof Highlight !== 'undefined';
}

function clear() {
  if (!highlightsSupported()) return;
  for (const name of NAMES) CSS.highlights.delete(name);
}

/**
 * A DOM range for a character offset range inside one surface.
 *
 * Returns null rather than throwing when the offsets do not resolve: a
 * highlight that cannot be placed is a highlight that is not drawn, which is
 * the right outcome while the pane is mid-render.
 */
function domRange(root, range) {
  const start = positionForOffset(root, range.location);
  const end = positionForOffset(root, range.location + range.length);
  if (!start || !end) return null;
  const domRange = document.createRange();
  try {
    domRange.setStart(start.node, start.offset);
    domRange.setEnd(end.node, end.offset);
  } catch {
    return null;
  }
  return domRange;
}

/**
 * Paints every outstanding finding's passage.
 *
 * @param {object} options
 * @param {Array<{id: string, range: {location: number, length: number}, severity: string}>} options.highlights
 * @param {string|null} options.selectedID the open card, drawn stronger
 * @param {Array<{root: HTMLElement, map: (range: object) => object|null}>} options.surfaces
 */
export function paintCritiqueHighlights({ highlights, selectedID, surfaces }) {
  if (!highlightsSupported()) return;
  clear();
  if (highlights.length === 0) return;

  const buckets = new Map();
  for (const entry of highlights) {
    const name = `me-critique-${entry.id === selectedID ? 'selected-' : ''}${entry.severity}`;
    const ranges = buckets.get(name) ?? [];
    for (const surface of surfaces) {
      if (!surface.root || surface.root.offsetParent === null) continue;
      const mapped = surface.map(entry.range);
      if (!mapped || mapped.length <= 0) continue;
      const range = domRange(surface.root, mapped);
      if (range) ranges.push(range);
    }
    buckets.set(name, ranges);
  }

  for (const [name, ranges] of buckets) {
    if (ranges.length === 0) continue;
    CSS.highlights.set(name, new Highlight(...ranges));
  }
}

export function clearCritiqueHighlights() {
  clear();
}
