// Live updates: keeping what is on screen equal to what is on the server.
//
// The backends can push (`api.watchFolder`, `api.watchDocument`,
// `api.watchAssets`); this module decides what to do about it. That split is
// the point. A watcher knows a document changed, but only this layer knows
// whether someone is halfway through a sentence in it.
//
// The rule everything here follows: **a change arriving from elsewhere may
// never destroy work that is in front of the user.** Every branch below is
// that rule applied to one situation.
//
// Three things are watched, and only in cloud mode, because the local backend
// subscribes to nothing (see `backends/local.js`):
//
//   the open document   — its text changed, or it was deleted
//   the visible folders — a document appeared, vanished, or was renamed
//   its assets folder   — an image it references finished uploading elsewhere

import { api } from './api.js';

/**
 * Applies a remote revision of the open document.
 *
 * Split out from the subscription so it can be tested without a Firestore, a
 * DOM, or a timer: everything below is a decision, and all of it is reachable
 * by calling this with a plain object.
 *
 * @returns {'ignored'|'applied'|'deferred'|'detached'} what was decided, which
 *   is also what the tests assert on.
 */
export function receiveDocumentRevision({ model, revision, onConflict, onDetached }) {  // The document was deleted, or moved, on another device.
  if (revision === null) {
    // Already detached — a second notification about the same deletion, or
    // this browser is the one that deleted it.
    if (model.isUntitled) return 'ignored';
    model.detach();
    onDetached();
    return 'detached';
  }

  // Nothing to do: this browser's own save, coming back off the server a
  // moment after it was sent.
  //
  // `savedSource` is by definition the last text this browser wrote or read,
  // so a revision equal to it carries no news — and that has to be the test
  // rather than comparing against `source`, because autosave fires while
  // people keep typing. Comparing against the text on screen would call the
  // echo of our own save a change from another device every time.
  if (revision.text === model.savedSource) return 'ignored';

  // There are unsaved edits on this screen. Adopting the incoming text would
  // throw them away, and no notification afterwards could bring them back, so
  // the incoming revision waits. The document stays dirty, which means the
  // next save writes this browser's version — last write wins, and the person
  // who is actually typing is the one who wins it.
  if (model.isDirty) {
    onConflict(revision);
    return 'deferred';
  }

  return model.applyRemote(revision) ? 'applied' : 'ignored';
}

/**
 * Calls `handler` whenever this tab comes back to the front.
 *
 * Separated from ``startLiveUpdates`` and injectable so that the coordinator
 * stays free of the DOM — it is tested under node, which has no `document` —
 * and so that a test can trigger a return without a browser.
 *
 * Both events are needed and neither is redundant. `visibilitychange` covers
 * switching tabs and unlocking a phone; `focus` covers moving between windows,
 * which does not change visibility. Firing twice is harmless: the second pass
 * reads the same bytes and recognises them as its own.
 *
 * @param {() => void} handler
 * @returns {() => void} a function that stops listening
 */
export function observeReturnToTab(handler) {
  if (typeof document === 'undefined' || typeof window === 'undefined') {
    return () => {};
  }
  const onVisibility = () => {
    if (document.visibilityState === 'hidden') return;
    handler();
  };
  document.addEventListener('visibilitychange', onVisibility);
  window.addEventListener('focus', onVisibility);
  return () => {
    document.removeEventListener('visibilitychange', onVisibility);
    window.removeEventListener('focus', onVisibility);
  };
}

/**
 * Starts watching, and returns a function that stops.
 *
 * @param {object} options
 * @param {import('./document.js').MarkdownDocumentModel} options.model
 * @param {object} options.explorer
 * @param {(message: string) => void} options.notify a transient status message
 * @param {(revision: object) => void} options.onConflict an incoming revision
 *   that was not applied because there are unsaved edits on screen. It is
 *   handed over rather than dropped: it is the only copy this browser has of
 *   what the other device wrote, and dropping it makes the notice useless.
 * @param {() => void} options.onDocumentChanged re-render after text arrived
 * @param {(handler: () => void) => () => void} [options.observeReturn]
 */
export function startLiveUpdates({
  model,
  explorer,
  notify,
  onConflict = () => {},
  onDocumentChanged,
  observeReturn = observeReturnToTab,
}) {
  /** folder path -> unsubscribe */
  const folderWatchers = new Map();
  let documentWatchers = [];
  let watchedPath = null;
  let stopped = false;

  function syncFolders() {
    if (stopped) return;
    const wanted = new Set(explorer.visibleFolders());

    for (const [path, unsubscribe] of folderWatchers) {
      if (wanted.has(path)) continue;
      unsubscribe();
      folderWatchers.delete(path);
    }

    for (const path of wanted) {
      if (folderWatchers.has(path)) continue;

      // The slot is claimed *before* subscribing, because a subscription can
      // call back synchronously, and anything that redraws the sidebar calls
      // straight back into this function. Without the claim that re-entrant
      // pass would not see this folder as watched and would subscribe to it
      // again, and again, until the stack ran out.
      folderWatchers.set(path, () => {});

      // Firestore delivers the current contents as soon as a listener is
      // attached. The sidebar has just rendered that same listing, so the
      // first callback is dropped: applying it would be a re-render that
      // changes nothing.
      let isFirst = true;
      const unsubscribe = api.watchFolder(path, (payload) => {
        if (isFirst) {
          isFirst = false;
          return;
        }
        explorer.applyLiveListing(path, payload.entries);
      });

      // A re-entrant pass may have decided this folder is no longer visible.
      if (folderWatchers.has(path)) folderWatchers.set(path, unsubscribe);
      else unsubscribe();
    }
  }

  function stopDocumentWatchers() {
    for (const unsubscribe of documentWatchers) unsubscribe();
    documentWatchers = [];
    watchedPath = null;
  }

  /** Follows the open document, including when it becomes a different one. */
  function syncDocument() {
    if (stopped) return;
    const path = model.path;
    if (path === watchedPath) return;
    stopDocumentWatchers();
    if (path === null) return;

    watchedPath = path;
    documentWatchers = [
      api.watchDocument(path, (revision) => {
        // A revision for a document that is no longer open. It can only be in
        // flight from the previous subscription, and acting on it would
        // overwrite the document that replaced it.
        if (model.path !== path) return;

        // Firestore delivers the current contents as soon as a listener is
        // attached, which needs no special case here: that text is what this
        // browser last read or wrote, so `receiveDocumentRevision` recognises
        // it as an echo and says nothing. Skipping the attach snapshot
        // outright would be worse — a document renamed while dirty starts
        // being followed under its new path, and if another device had
        // changed it in the meantime that first snapshot is the only notice
        // of it.
        const outcome = receiveDocumentRevision({
          model,
          revision,
          onConflict,
          onDetached: () => notify('Deleted on another device'),
        });
        if (outcome === 'applied') {
          notify('Updated from another device');
          onDocumentChanged();
        }
      }),
      api.watchAssets(path, () => {
        if (model.path === path) onDocumentChanged();
      }),
    ];
  }

  /**
   * WC-9: re-reads the open document on returning to the tab.
   *
   * Watchers only hear about writes made while somebody was listening, and
   * there are two ways to have not been. A backend may push nothing at all —
   * the local one is a PHP script and says so (WC-7) — and even a backend that
   * does push is talking to a tab the browser may have thrown off the CPU
   * while it was in the background.
   *
   * Coming back is the moment worth spending a read on: it is when the file is
   * most likely to have moved on, and it is one request per return rather than
   * a request every few seconds forever, which is what WC-7 rejected. The
   * answer goes through the same policy as a pushed revision, so there is one
   * set of rules about whose text wins, not two.
   */
  async function revalidate() {
    if (stopped) return 'ignored';
    const path = model.path;
    if (path === null) return 'ignored';

    let revision = null;
    try {
      revision = await api.read(path);
    } catch {
      // Offline, signed out, or the document is gone. None of those are worth
      // interrupting somebody who has just come back to their work; the next
      // save reports the real problem, in context.
      return 'ignored';
    }

    // Somebody opened a different document between the request and its answer.
    if (stopped || model.path !== path) return 'ignored';

    const outcome = receiveDocumentRevision({
      model,
      revision,
      onConflict,
      onDetached: () => notify('Deleted on another device'),
    });
    if (outcome === 'applied') {
      notify('Updated — changed by something else');
      onDocumentChanged();
    }
    return outcome;
  }

  function revalidateIfVisible() {
    revalidate();
  }

  explorer.onFoldersChanged = syncFolders;
  model.addEventListener('change', syncDocument);
  model.addEventListener('open', syncDocument);
  const stopObservingReturns = observeReturn(revalidateIfVisible);
  syncFolders();
  syncDocument();

  stopLiveUpdates.revalidate = revalidate;
  return stopLiveUpdates;

  function stopLiveUpdates() {
    stopped = true;
    explorer.onFoldersChanged = () => {};
    model.removeEventListener('change', syncDocument);
    model.removeEventListener('open', syncDocument);
    stopObservingReturns();
    for (const unsubscribe of folderWatchers.values()) unsubscribe();
    folderWatchers.clear();
    stopDocumentWatchers();
  }
}
