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
import { textReplacement } from '../core/text-difference.js';
import { insertNewline } from '../core/formatting.js';
import { readPlainText, selectionRange, setSelectionRange } from '../dom-text.js';

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
    setSelectionRange(this.element, surfaceRange);
    this.isApplying = false;
  }

  /** The document selection implied by the current DOM selection. */
  currentSourceSelection() {
    const surfaceRange = selectionRange(this.element);
    if (!surfaceRange) return null;
    return this.projection.toSource(this.model.source, surfaceRange);
  }

  handleSelectionChange = () => {
    if (this.isApplying || !this.isFocused) return;
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
    if (event.inputType === 'insertParagraph' || event.inputType === 'insertLineBreak') {
      event.preventDefault();
      const selection = this.currentSourceSelection() ?? this.model.selection;
      const result = insertNewline(this.model.source, selection);
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

    const previousText = this.projection.textFor(this.model.source);
    const currentText = readPlainText(this.element);
    if (currentText === previousText) return;

    const surfaceSelection = selectionRange(this.element) ?? makeRange(currentText.length, 0);

    // The caret sits after the inserted text, so the edited region is bounded
    // by the caret and the length change — enough for the diff to confirm or
    // widen on its own.
    const lengthDelta = currentText.length - previousText.length;
    const changeEnd = Math.max(0, surfaceSelection.location);
    const changeStart = Math.max(0, changeEnd - Math.max(0, lengthDelta));
    const guess = makeRange(changeStart, Math.max(0, -lengthDelta));

    const surfaceChange = textReplacement(previousText, currentText, guess);
    const sourceRange = this.projection.toSource(this.model.source, surfaceChange.range);
    const newSource =
      this.model.source.slice(0, sourceRange.location) +
      surfaceChange.replacement +
      this.model.source.slice(maxRange(sourceRange));

    const caret = makeRange(sourceRange.location + surfaceChange.replacement.length, 0);
    this.renderedSource = null; // the DOM no longer matches any known source
    this.model.edit(newSource, caret, { coalesce: true });
  };

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
