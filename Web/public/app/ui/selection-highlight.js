// The document's selection, drawn by the editor rather than the browser
// (T-24): a rounded bar per line, fading out past a line's end and in before
// the next line's start where the selection carries on, as the Mac draws it.
//
// The browser has no way to round `::selection` or to fade it, so its own
// highlight is switched off in the surface — only while this is drawing —
// and bars are laid over the text instead. Nothing is ever inserted into the
// surface: it is contenteditable, and an element in it would move every offset
// after it and land in the undo stack. The bars live in a layer after the
// surface, inside the same scrolling pane, so they scroll with the words
// without being redrawn.
//
// Over the words rather than under them, so the bars blend instead of simply
// painting (see selectionPaint): the words keep their own colours.

import {
  barBackground,
  groupIntoLines,
  parseCssColor,
  segmentsForLines,
  selectionPaint,
} from '../core/selection-geometry.js';

export class SelectionHighlight {
  /** @param {HTMLElement} surface - The contenteditable document surface. */
  constructor(surface) {
    this.surface = surface;
    this.pane = surface.parentElement;
    this.layer = document.createElement('div');
    this.layer.className = 'me-selection-layer';
    this.layer.setAttribute('aria-hidden', 'true');
    this.clip = document.createElement('div');
    this.clip.className = 'me-selection-layer__clip';
    this.layer.append(this.clip);
    this.surface.after(this.layer);

    this.bars = [];
    this.frame = 0;
    this.enabled = false;
    this.failed = false;
    this.probe = document.createRange();

    const schedule = () => this.refresh();
    document.addEventListener('selectionchange', schedule);
    // Bars are only built for the lines near the screen, so a scroll can
    // bring lines into view that have none yet.
    this.pane.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    // Focus decides the colour: the theme's tint while the document has it,
    // a quiet grey while it has gone elsewhere.
    window.addEventListener('focus', schedule);
    window.addEventListener('blur', schedule);
    document.addEventListener('focusin', schedule);
    document.addEventListener('focusout', schedule);
    // Anything that reflows the words moves them out from under their bars.
    if (typeof ResizeObserver === 'function') {
      const resized = new ResizeObserver(schedule);
      resized.observe(this.surface);
      resized.observe(this.pane);
    }
    document.fonts?.addEventListener?.('loadingdone', schedule);
    new MutationObserver(() => {
      this.updateEnabled();
      schedule();
    }).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['data-theme-color', 'data-appearance', 'data-me-layout', 'style', 'class'],
    });
    // A finger selects with the platform's own handles and highlight; drawing
    // a second one over it would only disagree with them.
    this.finePointer = window.matchMedia?.('(pointer: fine)') ?? null;
    this.finePointer?.addEventListener?.('change', () => {
      this.updateEnabled();
      schedule();
    });
    this.updateEnabled();
  }

  /** Draw again on the next frame, once however many times it is asked. */
  refresh() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.update();
    });
  }

  updateEnabled() {
    const enabled =
      !this.failed &&
      document.documentElement.dataset.meLayout !== 'mobile' &&
      (this.finePointer ? this.finePointer.matches : true) &&
      typeof CSS !== 'undefined' &&
      CSS.supports?.('mix-blend-mode', 'multiply') === true;
    if (enabled === this.enabled) return;
    this.enabled = enabled;
    this.layer.hidden = !enabled;
    if (enabled) this.surface.dataset.drawsSelection = 'true';
    else delete this.surface.dataset.drawsSelection;
    if (!enabled) this.clear();
  }

  update() {
    if (!this.enabled) {
      this.clear();
      return;
    }
    try {
      this.draw();
    } catch (error) {
      // A selection nobody can see is worse than a square one: hand it back
      // to the browser for good rather than risk drawing nothing again.
      console.error('Selection highlight failed; using the browser\u2019s own.', error);
      this.failed = true;
      this.updateEnabled();
    }
  }

  clear() {
    for (const bar of this.bars) bar.remove();
    this.bars = [];
  }

  draw() {
    const selection = document.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
      this.clear();
      return;
    }

    const paneRect = this.pane.getBoundingClientRect();
    // A screen's worth either side, so an ordinary scroll finds its bars
    // already there.
    const reach = { top: paneRect.top - paneRect.height, bottom: paneRect.bottom + paneRect.height };
    this.lineHeights = new Map();
    const segments = [];
    for (let index = 0; index < selection.rangeCount; index += 1) {
      const range = this.withinSurface(selection.getRangeAt(index));
      if (!range || range.collapsed) continue;
      const { boxes, continuesBefore, continuesAfter } = this.measure(range, reach);
      segments.push(...segmentsForLines(groupIntoLines(boxes), { continuesBefore, continuesAfter }));
    }
    if (segments.length === 0) {
      this.clear();
      return;
    }

    const styles = getComputedStyle(this.pane);
    const page = parseCssColor(styles.backgroundColor);
    const tint = parseCssColor(
      styles.getPropertyValue(
        this.isActive() ? '--me-text-selection-background' : '--me-inactive-text-selection-background'
      )
    ) ?? parseCssColor(styles.getPropertyValue('--me-text-selection-background'));
    if (!page || !tint) throw new Error('the theme has no selection colours');
    const paint = selectionPaint(tint, page);

    const layerRect = this.layer.getBoundingClientRect();
    const surfaceRect = this.surface.getBoundingClientRect();

    // Measured everything; now write. The clip covers the surface and no
    // more, so a fade reaching past the pane's edge cannot make it scroll
    // sideways.
    if (this.layer.dataset.blend !== paint.blend) this.layer.dataset.blend = paint.blend;
    setStyle(this.clip, 'top', `${surfaceRect.top - layerRect.top}px`);
    setStyle(this.clip, 'height', `${surfaceRect.height}px`);
    for (let index = 0; index < segments.length; index += 1) {
      const segment = segments[index];
      let bar = this.bars[index];
      if (!bar) {
        bar = document.createElement('div');
        bar.className = 'me-selection-bar';
        this.clip.append(bar);
        this.bars.push(bar);
      }
      setStyle(bar, 'left', `${segment.x - layerRect.left}px`);
      setStyle(bar, 'top', `${segment.y - surfaceRect.top}px`);
      setStyle(bar, 'width', `${segment.width}px`);
      setStyle(bar, 'height', `${segment.height}px`);
      setStyle(bar, 'borderRadius', `${segment.cornerRadius}px`);
      setStyle(bar, 'background', barBackground(segment, paint.colour));
    }
    for (const extra of this.bars.splice(segments.length)) extra.remove();
  }

  /** The document's own tint only while the document has the focus. */
  isActive() {
    const focused = document.activeElement;
    return document.hasFocus() && (focused === this.surface || this.surface.contains(focused));
  }

  /** The part of `range` inside the surface, or null if none of it is. */
  withinSurface(range) {
    if (!range.intersectsNode(this.surface)) return null;
    if (this.surface.contains(range.startContainer) && this.surface.contains(range.endContainer)) {
      return range;
    }
    const clamped = range.cloneRange();
    if (!this.surface.contains(range.startContainer)) clamped.setStart(this.surface, 0);
    if (!this.surface.contains(range.endContainer)) {
      clamped.setEnd(this.surface, this.surface.childNodes.length);
    }
    return clamped;
  }

  /**
   * The boxes to shade for `range`, block by block, skipping blocks too far
   * off screen to matter — and whether the selection carries on past the
   * first and last lines measured.
   *
   * Every block but the last has its break selected, so one with nothing else
   * selected — an empty line, or the line a selection starts at the very end
   * of — still gets a sliver where its break is. A last block with nothing
   * selected means the selection ended on the break before it.
   */
  measure(range, reach) {
    const boxes = [];
    let continuesBefore = false;
    let continuesAfter = false;
    const { first, last } = this.boundaryBlocks(range);
    if (!first || !last) return { boxes, continuesBefore, continuesAfter };

    for (let block = first; block; block = block.nextElementSibling) {
      const isLast = block === last;
      const rect = block.getBoundingClientRect();
      if (rect.bottom < reach.top) {
        continuesBefore = true;
        if (isLast) break;
        continue;
      }
      if (rect.top > reach.bottom) {
        continuesAfter = true;
        break;
      }
      const found = this.boxesIn(block, range);
      if (found.length === 0) {
        if (!isLast) {
          const marker = block === first
            ? this.caretBox(block, range.startContainer, range.startOffset)
            : this.emptyLineBox(block);
          if (marker) found.push(marker);
        } else if (boxes.length > 0 || continuesBefore) {
          continuesAfter = true;
        }
      }
      boxes.push(...found);
      if (isLast) break;
    }
    // A break inside a block — a hard line break in a paragraph — as the last
    // thing selected carries on to the next line just as a block's does.
    const end = range.endContainer;
    if (end.nodeType === Node.TEXT_NODE && range.endOffset > 0 && end.data[range.endOffset - 1] === '\n') {
      continuesAfter = true;
    }
    return { boxes, continuesBefore, continuesAfter };
  }

  /** The first and last blocks `range` touches. */
  boundaryBlocks(range) {
    const surface = this.surface;
    const blockOf = (container, offset, isEnd) => {
      if (container === surface) {
        const children = surface.childNodes;
        if (isEnd) {
          if (offset === 0) return null;
          return elementAtOrBefore(children, offset < children.length ? offset : children.length - 1);
        }
        return elementAtOrAfter(children, offset);
      }
      let node = container;
      while (node && node.parentNode !== surface) node = node.parentNode;
      return node instanceof Element ? node : null;
    };
    return {
      first: blockOf(range.startContainer, range.startOffset, false),
      last: blockOf(range.endContainer, range.endOffset, true),
    };
  }

  /** The shaded boxes of whatever `range` selects inside `block`. */
  boxesIn(block, range) {
    const lineHeight = this.lineHeightOf(block);
    const probe = this.probe;
    const boxes = [];
    const walk = (parent) => {
      for (let node = parent.firstChild; node; node = node.nextSibling) {
        if (node.nodeType === Node.TEXT_NODE) {
          if (!range.intersectsNode(node)) continue;
          const start = node === range.startContainer ? range.startOffset : 0;
          const end = node === range.endContainer ? range.endOffset : node.length;
          if (end <= start) continue;
          probe.setStart(node, start);
          probe.setEnd(node, end);
          for (const rect of probe.getClientRects()) {
            if (rect.height > 0) boxes.push(glyphBox(rect, lineHeight));
          }
        } else if (node.nodeType === Node.ELEMENT_NODE) {
          if (node.classList.contains('me-image')) {
            // One unit, measured as the picture it shows; its placeholder
            // character is laid out in a zero-size holder and is not ink.
            if (containsNode(range, node)) {
              const shown = (node.querySelector('img') ?? node).getBoundingClientRect();
              if (shown.height > 0) {
                boxes.push({ left: shown.left, right: shown.right, top: shown.top, bottom: shown.bottom });
              }
            }
            continue;
          }
          if (node.tagName === 'BR') continue;
          walk(node);
        }
      }
    };
    walk(block);
    return boxes;
  }

  /** A sliver at a caret position: where a selection starts on a break. */
  caretBox(block, container, offset) {
    const probe = this.probe;
    probe.setStart(container, offset);
    probe.collapse(true);
    let rects = probe.getClientRects();
    if (rects.length === 0 && container.nodeType === Node.ELEMENT_NODE) {
      // A caret between elements has no box of its own; the text beside it does.
      const before = container.childNodes[offset - 1];
      const text = before ? lastTextIn(before) : null;
      if (text) {
        probe.setStart(text, text.length);
        probe.collapse(true);
        rects = probe.getClientRects();
      }
    }
    const rect = rects[rects.length - 1];
    return rect && rect.height > 0 ? glyphBox(rect, this.lineHeightOf(block)) : this.emptyLineBox(block);
  }

  /** A sliver at the start of a block with nothing in it but its break. */
  emptyLineBox(block) {
    const lineHeight = this.lineHeightOf(block);
    const br = block.querySelector('br');
    const rect = br?.getBoundingClientRect();
    if (rect && rect.height > 0) {
      return glyphBox({ left: rect.left, right: rect.left, top: rect.top, bottom: rect.bottom }, lineHeight);
    }
    const whole = block.getBoundingClientRect();
    const styles = getComputedStyle(block);
    const left = whole.left + (parseFloat(styles.paddingLeft) || 0);
    const top = whole.top + (parseFloat(styles.paddingTop) || 0);
    const height = Number.isFinite(lineHeight) ? lineHeight : whole.height;
    return glyphBox({ left, right: left, top, bottom: top + height }, lineHeight);
  }

  lineHeightOf(block) {
    let height = this.lineHeights?.get(block);
    if (height === undefined) {
      height = parseFloat(getComputedStyle(block).lineHeight);
      this.lineHeights?.set(block, height);
    }
    return height;
  }
}

/** Glyphs, and the height of the line they stand on; see groupIntoLines. */
function glyphBox(rect, lineHeight) {
  return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, lineHeight };
}

/** Whether `range` holds all of `node`, not just a boundary touching it. */
function containsNode(range, node) {
  const parent = node.parentNode;
  if (!parent) return false;
  const index = Array.prototype.indexOf.call(parent.childNodes, node);
  return range.comparePoint(parent, index) === 0 && range.comparePoint(parent, index + 1) === 0;
}

function lastTextIn(node) {
  if (node.nodeType === Node.TEXT_NODE) return node;
  for (let child = node.lastChild; child; child = child.previousSibling) {
    const found = lastTextIn(child);
    if (found) return found;
  }
  return null;
}

function elementAtOrAfter(children, index) {
  for (let i = index; i < children.length; i += 1) {
    if (children[i] instanceof Element) return children[i];
  }
  return null;
}

function elementAtOrBefore(children, index) {
  for (let i = index; i >= 0; i -= 1) {
    if (children[i] instanceof Element) return children[i];
  }
  return null;
}

/**
 * Writes only what changed, so an unchanged bar costs the page nothing. What
 * was written is remembered rather than read back, because the browser reads
 * a colour or a gradient back in its own spelling.
 */
const written = new WeakMap();
function setStyle(element, property, value) {
  let values = written.get(element);
  if (!values) written.set(element, (values = {}));
  if (values[property] === value) return;
  values[property] = value;
  element.style[property] = value;
}
