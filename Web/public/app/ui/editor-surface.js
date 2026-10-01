// A contenteditable surface over the Markdown source.
//
// One class drives both panes. The difference between them is entirely in the
// `projection` it is given:
//
//   source pane — the DOM text *is* the Markdown, so mapping is the identity
//   rich pane   — the DOM text is the rendered text, and mapping goes through
//                 the render model's per-character source ranges (M-5)
//
// Editing works the same way in both: read what the DOM now says, diff it
// against what the projection last produced, translate that to a replacement
// against the Markdown source, and hand the whole new source to the document.
// Because the diff is minimal, untouched text is never rewritten (E-7).

import { makeRange, maxRange } from '../core/range.js';
import { minimalReplacement, textReplacement } from '../core/text-difference.js';
import { insertNewline } from '../core/formatting.js';
import {
  blockContaining,
  blockIndexOf,
  readPlainText,
  selectionRange,
  setSelectionRange,
  textOfBlock,
} from '../dom-text.js';

/**
 * How far either side of an edit the surface will look for the unchanged text
 * that brackets it, before giving up and comparing the whole document.
 *
 * A browser confines an edit to the selection, so one block either side is
 * already generous. The allowance exists so that a browser doing something
 * unforeseen costs a slow keystroke rather than a wrong one.
 */
const BRACKET_SEARCH_LIMIT = 8;

export class EditorSurface {
  /**
   * @param {HTMLElement} element the contenteditable host
   * @param {object} projection
   * @param {(source: string) => void} projection.render draws `source` into the element
   * @param {(source: string) => string} projection.textFor the plain text `render` produces
   * @param {(source: string, range) => range} projection.toSource maps a surface range to source
   * @param {(source: string, range) => range} projection.toSurface maps a source range to the surface
   * @param {MarkdownDocumentModel} model
   */
  constructor(element, projection, model) {
    this.element = element;
    this.projection = projection;
    this.model = model;

    this.isComposing = false;
    this.isApplying = false;
    this.renderedSource = null;
    /** The blocks the selection spanned before the browser changed anything. */
    this.pendingBlocks = null;
    this.onSelectionChange = () => {};

    element.contentEditable = supportsPlainTextOnly() ? 'plaintext-only' : 'true';
    element.spellcheck = element.getAttribute('spellcheck') !== 'false';

    element.addEventListener('beforeinput', this.handleBeforeInput);
    element.addEventListener('input', this.handleInput);
    element.addEventListener('compositionstart', () => {
      this.isComposing = true;
    });
    element.addEventListener('compositionend', () => {
      this.isComposing = false;
      this.handleInput();
    });
    element.addEventListener('copy', this.handleCopy);
    element.addEventListener('cut', this.handleCut);
    element.addEventListener('paste', this.handlePaste);
    document.addEventListener('selectionchange', this.handleSelectionChange);
  }

  get isFocused() {
    return document.activeElement === this.element;
  }

  focus() {
    this.element.focus();
  }

  /**
   * How the surface is laid out in blocks, when the projection can say.
   *
   * Every offset lookup can then be a binary search over the blocks rather
   * than a walk from the top of the document.
   */
  layout() {
    return this.projection.layoutFor?.(this.model.source) ?? null;
  }

  /** Redraws only when the projection's output would actually change. */
  sync(source, selection, { force = false } = {}) {
    const shouldRender = force || source !== this.renderedSource;
    if (shouldRender) {
      this.isApplying = true;
      this.projection.render(source);
      this.renderedSource = source;
      this.isApplying = false;
    }
    if (this.isFocused || shouldRender) {
      this.applySelection(source, selection);
    }
  }

  applySelection(source, selection) {
    if (!this.isFocused) return;
    const surfaceRange = this.projection.toSurface(source, selection);
    this.isApplying = true;
    setSelectionRange(this.element, surfaceRange, this.layout());
    this.isApplying = false;
  }

  /** The document selection implied by the current DOM selection. */
  currentSourceSelection() {
    const surfaceRange = selectionRange(this.element, this.layout());
    if (!surfaceRange) return null;
    return this.projection.toSource(this.model.source, surfaceRange);
  }

  handleSelectionChange = () => {
    if (this.isApplying || !this.isFocused) return;
    this.noteSelectedBlocks();
    const selection = this.currentSourceSelection();
    if (selection) {
      this.model.selection = selection;
      this.onSelectionChange(selection);
    }
  };

  /**
   * Return runs through the shared formatting command so list and quote
   * continuation behaves identically in both panes and in both apps
   * (F-12 through F-15).
   */
  handleBeforeInput = (event) => {
    // The DOM still matches what the surface was drawn from, so this is the
    // last chance to record what the edit is about to replace.
    this.noteSelectedBlocks();

    if (event.inputType === 'insertParagraph' || event.inputType === 'insertLineBreak') {
      event.preventDefault();
      const selection = this.currentSourceSelection() ?? this.model.selection;
      const result = insertNewline(this.model.source, selection, this.layout());
      this.model.edit(result.text, result.selection);
      return;
    }

    if (event.inputType === 'historyUndo') {
      event.preventDefault();
      this.model.undo();
      return;
    }

    if (event.inputType === 'historyRedo') {
      event.preventDefault();
      this.model.redo();
    }
  };

  handleInput = () => {
    if (this.isApplying || this.isComposing) return;

    const surfaceChange = this.changedRegion() ?? this.changedDocument();
    if (surfaceChange === null) return;

    const sourceRange = this.projection.toSource(this.model.source, surfaceChange.range);
    const newSource =
      this.model.source.slice(0, sourceRange.location) +
      surfaceChange.replacement +
      this.model.source.slice(maxRange(sourceRange));

    const caret = makeRange(sourceRange.location + surfaceChange.replacement.length, 0);
    this.renderedSource = null; // the DOM no longer matches any known source
    this.model.edit(newSource, caret, {
      coalesce: true,
      // The render model would otherwise have to find this out by comparing
      // the whole document against the whole document.
      change: {
        previousSource: this.model.source,
        range: sourceRange,
        replacement: surfaceChange.replacement,
      },
    });
  };

  /**
   * What the browser just changed, read from the blocks it could have touched.
   *
   * An edit is confined to the selection it replaced, so the blocks that can
   * differ run from wherever the selection started to wherever the caret ended
   * up. Reading those and comparing them against the model the surface was
   * drawn from is work proportional to the edit; reading the whole surface, as
   * this used to, is work proportional to the document.
   *
   * Returns null when the surface cannot be sure — an unexpected block count,
   * a selection it cannot place, or text that does not line up on both sides
   * of the region — leaving the caller to compare everything instead.
   */
  changedRegion() {
    const layout = this.projection.layoutFor?.(this.model.source);
    if (!layout || this.pendingBlocks === null) return null;

    const root = this.element;
    const domCount = root.childNodes.length;
    const modelCount = layout.blockCount;
    if (domCount === 0 || modelCount === 0) return null;

    const caretBlock = this.caretBlockIndex();
    if (caretBlock === -1) return null;

    // How many blocks the browser added or removed.
    const grew = domCount - modelCount;
    let low = Math.max(0, Math.min(this.pendingBlocks.first, caretBlock));
    let modelHigh = Math.min(
      modelCount,
      Math.max(this.pendingBlocks.last + 1, caretBlock + 1 - grew)
    );
    let domHigh = modelHigh + grew;
    if (domHigh < low || domHigh > domCount || modelHigh < low) return null;

    // The text either side of the region has to be the text the model says is
    // there, or the region is not the whole of what moved.
    let widened = 0;
    while (low > 0 && textOfBlock(root.childNodes[low - 1]) !== layout.blockText(low - 1)) {
      if (widened >= BRACKET_SEARCH_LIMIT) return null;
      low -= 1;
      widened += 1;
    }
    while (
      domHigh < domCount &&
      modelHigh < modelCount &&
      textOfBlock(root.childNodes[domHigh]) !== layout.blockText(modelHigh)
    ) {
      if (widened >= BRACKET_SEARCH_LIMIT) return null;
      domHigh += 1;
      modelHigh += 1;
      widened += 1;
    }
    if (domHigh > domCount || modelHigh > modelCount) return null;

    const before = joinBlocks(low, modelHigh, (index) => layout.blockText(index));
    const after = joinBlocks(low, domHigh, (index) => textOfBlock(root.childNodes[index]));
    if (before === after) return null;

    const base = layout.blockRenderedStart(low);
    // Measured rather than guessed: the region is already only what could have
    // changed, and taking it whole would rewrite the text around the edit.
    const change = minimalReplacement(before, after);
    return {
      range: makeRange(base + change.range.location, change.range.length),
      replacement: change.replacement,
    };
  }

  /** The whole surface against the whole projection, when nothing else fits. */
  changedDocument() {
    const previousText = this.projection.textFor(this.model.source);
    const currentText = readPlainText(this.element);
    if (currentText === previousText) return null;

    const surfaceSelection = selectionRange(this.element) ?? makeRange(currentText.length, 0);

    // The caret sits after the inserted text, so the edited region is bounded
    // by the caret and the length change — enough for the diff to confirm or
    // widen on its own.
    const lengthDelta = currentText.length - previousText.length;
    const changeEnd = Math.max(0, surfaceSelection.location);
    const changeStart = Math.max(0, changeEnd - Math.max(0, lengthDelta));
    const guess = makeRange(changeStart, Math.max(0, -lengthDelta));

    return textReplacement(previousText, currentText, guess);
  }

  /** Which block the caret is in now, without counting from the top. */
  caretBlockIndex() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return -1;
    const node = selection.getRangeAt(0).endContainer;
    if (node === this.element) {
      return Math.min(selection.getRangeAt(0).endOffset, this.element.childNodes.length - 1);
    }
    if (!this.element.contains(node)) return -1;
    const block = blockContaining(this.element, node);
    return block === null ? -1 : blockIndexOf(this.element, block);
  }

  /** The blocks the selection spans, recorded while the DOM still matches. */
  noteSelectedBlocks() {
    const layout = this.projection.layoutFor?.(this.model.source);
    if (!layout || this.element.childNodes.length !== layout.blockCount) {
      this.pendingBlocks = null;
      return;
    }
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) {
      this.pendingBlocks = null;
      return;
    }
    const range = selection.getRangeAt(0);
    const first = this.blockIndexAt(range.startContainer);
    const last = this.blockIndexAt(range.endContainer);
    this.pendingBlocks =
      first === -1 || last === -1
        ? null
        : { first: Math.min(first, last), last: Math.max(first, last) };
  }

  blockIndexAt(node) {
    if (!this.element.contains(node) && node !== this.element) return -1;
    if (node === this.element) return 0;
    const block = blockContaining(this.element, node);
    return block === null ? -1 : blockIndexOf(this.element, block);
  }

  /**
   * E-9: copying places the underlying Markdown on the clipboard, both as
   * plain text and under a private type, so a round trip between documents
   * preserves formatting exactly (E-10).
   */
  handleCopy = (event) => {
    const selection = this.currentSourceSelection();
    if (!selection || selection.length === 0) return;
    event.preventDefault();
    const markdown = this.model.source.slice(selection.location, maxRange(selection));
    event.clipboardData.setData('text/plain', markdown);
    event.clipboardData.setData('text/markdown', markdown);
  };

  /** E-11: cut copies the Markdown, then removes it as one undoable step. */
  handleCut = (event) => {
    const selection = this.currentSourceSelection();
    if (!selection || selection.length === 0) return;
    event.preventDefault();
    const markdown = this.model.source.slice(selection.location, maxRange(selection));
    event.clipboardData.setData('text/plain', markdown);
    event.clipboardData.setData('text/markdown', markdown);

    const newSource =
      this.model.source.slice(0, selection.location) +
      this.model.source.slice(maxRange(selection));
    this.model.edit(newSource, makeRange(selection.location, 0));
  };

  handlePaste = (event) => {
    const markdown =
      event.clipboardData.getData('text/markdown') ||
      event.clipboardData.getData('text/plain');

    const files = Array.from(event.clipboardData.files ?? []);
    if (files.length > 0 && this.onPasteFiles) {
      event.preventDefault();
      this.onPasteFiles(files);
      return;
    }
    if (!markdown) return;

    event.preventDefault();
    const selection = this.currentSourceSelection() ?? this.model.selection;
    const newSource =
      this.model.source.slice(0, selection.location) +
      markdown +
      this.model.source.slice(maxRange(selection));
    this.model.edit(newSource, makeRange(selection.location + markdown.length, 0));
  };
}

/** Block texts joined the way the projection joins them. */
function joinBlocks(from, to, textAt) {
  let text = '';
  for (let index = from; index < to; index += 1) {
    if (index > from) text += '\n';
    text += textAt(index);
  }
  return text;
}

let plainTextOnly = null;

/**
 * `plaintext-only` keeps the browser from inserting its own markup on paste
 * and Return, which is exactly what a Markdown editor wants. Where it is
 * unavailable the surface falls back to `true` and relies on the paste and
 * beforeinput handlers above.
 */
function supportsPlainTextOnly() {
  if (plainTextOnly !== null) return plainTextOnly;
  const probe = document.createElement('div');
  try {
    probe.contentEditable = 'plaintext-only';
    plainTextOnly = probe.contentEditable === 'plaintext-only';
  } catch {
    plainTextOnly = false;
  }
  return plainTextOnly;
}
