// Document state: the Markdown source, the undo stack, and autosave.
//
// The source string is the single source of truth (PRD G-1). Both editing
// surfaces are projections of it, and every edit — typed, pasted, or applied
// by a formatting command — arrives here as a whole new source plus a
// selection.

import { api } from './api.js';
import { clampRange, makeRange } from './core/range.js';

/** D-12: debounce after the last keystroke before autosaving in place. */
const AUTOSAVE_DELAY_MS = 1500;

/** Consecutive typing inside this window collapses into one undo step. */
const UNDO_COALESCE_MS = 600;

const UNTITLED = 'Untitled';

/**
 * D-5: what a new document starts as.
 *
 * An empty Heading 1 line, which is byte-for-byte what the Heading 1 command
 * produces on an empty document — so a new file is in the same state as one
 * where the first thing you did was choose Heading 1, and there is no second
 * kind of "new" for the rest of the editor to know about.
 *
 * It is a starting point, not a rule: nothing forces the first line to stay a
 * heading. Delete the marker and the line is a paragraph, which is what has to
 * happen anyway for every document that is opened rather than created.
 *
 * The document is not dirty when it holds exactly this, so making a new
 * document and then closing it still asks nothing.
 */
export const NEW_DOCUMENT_SOURCE = '# ';

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
    /** Where the document used to live, once its file has gone. */
    this.detachedPath = null;
  }

  get isUntitled() {
    return this.path === null;
  }

  get displayName() {
    return this.name;
  }

  /** What Save should offer for a document with no file behind it (WF-9). */
  get suggestedFileName() {
    if (this.detachedPath !== null) return this.detachedPath;
    return /\.(md|markdown)$/i.test(this.name) ? this.name : `${this.name}.md`;
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
    this.detachedPath = null;
    this.selection = makeRange(0, 0);
    this.undoStack = [];
    this.redoStack = [];
    this.cancelAutosave();
    this.notify('open');
    this.notify();
  }

  /** D-5: a new document starts on an empty Heading 1 line, caret inside it. */
  reset() {
    this.path = null;
    this.name = UNTITLED;
    this.source = NEW_DOCUMENT_SOURCE;
    this.savedSource = NEW_DOCUMENT_SOURCE;
    this.hasByteOrderMark = false;
    this.isDirty = false;
    this.detachedPath = null;
    this.selection = makeRange(NEW_DOCUMENT_SOURCE.length, 0);
    this.undoStack = [];
    this.redoStack = [];
    this.cancelAutosave();
    this.notify('open');
    this.notify();
  }

  /**
   * The file behind the document was renamed or moved. Only its location
   * changed, so the text, history, and unsaved state all carry over (WF-9).
   */
  relocate(path, name) {
    this.path = path;
    this.name = name;
    this.detachedPath = null;
    this.notify();
  }

  /**
   * The file behind the document is gone.
   *
   * The text stays on screen and becomes unsaved, so deleting a file in the
   * sidebar can never take away work that is still in front of the user. It is
   * held permanently dirty — `savedSource` is set to a value no string can
   * equal — because there is nothing on disk left to match.
   */
  detach() {
    this.detachedPath = this.path;
    this.path = null;
    this.savedSource = null;
    this.isDirty = true;
    this.cancelAutosave();
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
   * WC-6: a newer revision of this document arrived from the server.
   *
   * The old text goes onto the undo stack before the new text replaces it, so
   * a change made on another device is a normal undoable step: press Undo and
   * your version is back, dirty, and on its way to being autosaved again. That
   * matters because the alternative — clearing history the way `open()` does —
   * would make an arriving revision the one edit in the editor that cannot be
   * taken back.
   *
   * The caller decides *whether* to call this. It never checks `isDirty`
   * itself, because "there are unsaved edits" is a question about what the
   * person is doing, not about the text, and the answer lives in `live.js`.
   *
   * Returns false when the text is already what arrived, which is the common
   * case: this browser's own save echoing back off the server.
   */
  applyRemote({ text, hasByteOrderMark = this.hasByteOrderMark, name = this.name, path = this.path }) {
    if (text === this.source && text === this.savedSource) return false;

    if (text !== this.source) {
      this.undoStack.push({ source: this.source, selection: this.selection });
      if (this.undoStack.length > 500) this.undoStack.shift();
      this.redoStack = [];
      this.lastUndoPushAt = 0;
    }

    this.source = text;
    this.savedSource = text;
    this.hasByteOrderMark = hasByteOrderMark;
    this.name = name;
    this.path = path;
    this.isDirty = false;
    this.detachedPath = null;
    // The caret may have been past the end of the shorter incoming text.
    this.selection = clampRange(this.selection, text.length);
    this.cancelAutosave();
    this.notify('open');
    this.notify();
    return true;
  }

  /**
   * D-12 through D-16: autosave in place, but only for a document that already
   * exists on disk. An untitled document has nowhere to go, so it waits for an
   * explicit Save instead.
   */
  scheduleAutosave() {
    this.cancelAutosave();
    if (this.isUntitled || !this.isDirty) return;
    this.autosaveTimer = setTimeout(() => {
      this.autosaveTimer = null;
      this.save({ isAutosave: true }).catch((error) => {
        // D-17: autosave never fails silently.
        this.dispatchEvent(new CustomEvent('error', { detail: error }));
      });
    }, AUTOSAVE_DELAY_MS);
  }

  cancelAutosave() {
    if (this.autosaveTimer !== null) {
      clearTimeout(this.autosaveTimer);
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

    // What is actually sent, captured before the await.
    //
    // Reading `this.source` again afterwards would be reading it as it is when
    // the server replies, which is not what the server was given if anything
    // was typed while the request was in flight — a real gap at autosave
    // speeds. Recording the wrong text as saved used to cost one skipped
    // autosave. Now that a revision arriving from elsewhere is compared
    // against `savedSource` to recognise this browser's own echo, it would
    // cost those keystrokes instead, so this has to be exact.
    const written = this.source;

    const saved = await api.write(target, written, this.hasByteOrderMark);
    this.path = saved.path;
    this.name = saved.name;
    this.savedSource = written;
    this.isDirty = this.source !== written;
    this.detachedPath = null;
    this.cancelAutosave();
    this.notify(isAutosave ? 'autosaved' : 'saved');
    this.notify();
    // Anything typed during the write is still unsaved, and says so.
    if (this.isDirty) this.scheduleAutosave();
    return saved;
  }
}
