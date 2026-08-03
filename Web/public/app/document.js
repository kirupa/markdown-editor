// Document state: the Markdown source, the undo stack, and autosave.
//
// The source string is the single source of truth (PRD G-1). Both editing
// surfaces are projections of it, and every edit — typed, pasted, or applied
// by a formatting command — arrives here as a whole new source plus a
// selection.

import { api } from './api.js';
import { makeRange } from './core/range.js';

/** D-12: debounce after the last keystroke before autosaving in place. */
const AUTOSAVE_DELAY_MS = 1500;

/** Consecutive typing inside this window collapses into one undo step. */
const UNDO_COALESCE_MS = 600;

const UNTITLED = 'Untitled';

export class MarkdownDocumentModel extends EventTarget {
  constructor() {
    super();
    this.path = null;
    this.name = UNTITLED;
    this.source = '';
    this.hasByteOrderMark = false;
    this.isDirty = false;
    this.selection = makeRange(0, 0);

    this.undoStack = [];
    this.redoStack = [];
    this.lastUndoPushAt = 0;
    this.autosaveTimer = null;
    this.savedSource = '';
  }

  get isUntitled() {
    return this.path === null;
  }

  get displayName() {
    return this.name;
  }

  get canUndo() {
    return this.undoStack.length > 0;
  }

  get canRedo() {
    return this.redoStack.length > 0;
  }

  notify(kind = 'change') {
    this.dispatchEvent(new CustomEvent(kind));
  }

  /** Loads a document from the server and resets history. */
  async open(path) {
    const payload = await api.read(path);
    this.path = payload.path;
    this.name = payload.name;
    this.source = payload.text;
    this.savedSource = payload.text;
    this.hasByteOrderMark = payload.hasByteOrderMark;
    this.isDirty = false;
    this.selection = makeRange(0, 0);
    this.undoStack = [];
    this.redoStack = [];
    this.cancelAutosave();
    this.notify('open');
    this.notify();
  }

  /** D-5: a new document starts as an empty string. */
  reset() {
    this.path = null;
    this.name = UNTITLED;
    this.source = '';
    this.savedSource = '';
    this.hasByteOrderMark = false;
    this.isDirty = false;
    this.selection = makeRange(0, 0);
    this.undoStack = [];
    this.redoStack = [];
    this.cancelAutosave();
    this.notify('open');
    this.notify();
  }

  /**
   * Applies an edit.
   *
   * @param {string} source the complete new Markdown source
   * @param {import('./core/range.js').Range} selection where the caret lands
   * @param {{ coalesce?: boolean }} [options] `coalesce` merges this into the
   *   previous undo entry when they are close together in time, so a burst of
   *   typing is one undo step rather than one per character (E-12).
   */
  edit(source, selection, { coalesce = false } = {}) {
    if (source === this.source) {
      this.selection = selection;
      this.notify('selection');
      return;
    }

    const now = Date.now();
    const shouldCoalesce =
      coalesce &&
      this.undoStack.length > 0 &&
      now - this.lastUndoPushAt < UNDO_COALESCE_MS;

    if (!shouldCoalesce) {
      this.undoStack.push({ source: this.source, selection: this.selection });
      if (this.undoStack.length > 500) this.undoStack.shift();
    }
    this.lastUndoPushAt = now;
    this.redoStack = [];

    this.source = source;
    this.selection = selection;
    this.isDirty = source !== this.savedSource;
    this.notify();
    this.scheduleAutosave();
  }

  undo() {
    const entry = this.undoStack.pop();
    if (!entry) return false;
    this.redoStack.push({ source: this.source, selection: this.selection });
    this.source = entry.source;
    this.selection = entry.selection;
    this.isDirty = this.source !== this.savedSource;
    this.lastUndoPushAt = 0;
    this.notify();
    this.scheduleAutosave();
    return true;
  }

  redo() {
    const entry = this.redoStack.pop();
    if (!entry) return false;
    this.undoStack.push({ source: this.source, selection: this.selection });
    this.source = entry.source;
    this.selection = entry.selection;
    this.isDirty = this.source !== this.savedSource;
    this.lastUndoPushAt = 0;
    this.notify();
    this.scheduleAutosave();
    return true;
  }

  setSelection(selection) {
    this.selection = selection;
    this.notify('selection');
  }

  /**
   * D-12 through D-16: autosave in place, but only for a document that already
   * exists on disk. An untitled document has nowhere to go, so it waits for an
   * explicit Save instead.
   */
  scheduleAutosave() {
    this.cancelAutosave();
    if (this.isUntitled || !this.isDirty) return;
    this.autosaveTimer = window.setTimeout(() => {
      this.autosaveTimer = null;
      this.save({ isAutosave: true }).catch((error) => {
        // D-17: autosave never fails silently.
        this.dispatchEvent(new CustomEvent('error', { detail: error }));
      });
    }, AUTOSAVE_DELAY_MS);
  }

  cancelAutosave() {
    if (this.autosaveTimer !== null) {
      window.clearTimeout(this.autosaveTimer);
      this.autosaveTimer = null;
    }
  }

  /** D-14: flush a pending autosave immediately, e.g. when the tab is hidden. */
  async flushAutosave() {
    if (this.autosaveTimer === null) return;
    this.cancelAutosave();
    if (!this.isUntitled && this.isDirty) {
      await this.save({ isAutosave: true });
    }
  }

  async save({ path = null, isAutosave = false } = {}) {
    const target = path ?? this.path;
    if (!target) throw new Error('The document has no location to save to.');

    const saved = await api.write(target, this.source, this.hasByteOrderMark);
    this.path = saved.path;
    this.name = saved.name;
    this.savedSource = this.source;
    this.isDirty = false;
    this.cancelAutosave();
    this.notify(isAutosave ? 'autosaved' : 'saved');
    this.notify();
    return saved;
  }
}
