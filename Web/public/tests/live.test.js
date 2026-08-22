// Live updates: what happens when the server says something changed.
//
// Two layers are covered, and they are covered separately on purpose.
//
// `watchFolder` / `watchDocument` / `watchAssets` are the backend's shaping —
// a node from the database turned into the payload a caller already knows how
// to handle. Those run against the in-memory Firestore, whose watchers behave
// like the real ones: attaching delivers what is there right now.
//
// `receiveDocumentRevision` is the decision — adopt, defer, detach, or ignore.
// That is where every way this feature could destroy someone's work lives, so
// it is tested against a stub with no database underneath it at all.

import { suite, test, expect, expectEqual } from './harness.js';
import { createFirestoreBackend } from '../app/backends/firestore.js';
import {
  createMemoryNodeStore,
  createMemoryAssetStore,
  fileNode,
  folderNode,
  assetNode,
  fakeImage,
} from './support/memory-store.js';
import { receiveDocumentRevision, startLiveUpdates } from '../app/live.js';
import { MarkdownDocumentModel } from '../app/document.js';
import { setBackend } from '../app/api.js';
import { makeRange } from '../app/core/range.js';

function build(seed = []) {
  const nodes = createMemoryNodeStore(seed);
  const assets = createMemoryAssetStore();
  return { nodes, assets, backend: createFirestoreBackend({ nodes, assets }) };
}

/** Records what a listener was handed, so a test can assert on the sequence. */
function recorder() {
  const calls = [];
  const listener = (value) => calls.push(value);
  listener.calls = calls;
  listener.last = () => calls.at(-1);
  return listener;
}

suite('Live updates from the backend', () => {
  test('watching a folder delivers the same shape as listing it', async () => {
    const { backend, nodes } = build([folderNode('Notes'), fileNode('Notes/Ideas.md', '# Ideas')]);
    const seen = recorder();
    backend.watchFolder('Notes', seen);

    const listed = await backend.tree('Notes');
    expectEqual(seen.last(), listed, 'a push and a fetch must be interchangeable');
    nodes.watcherCount() > 0 || expect(false, 'the watcher should still be attached');
  });

  test('a document created elsewhere appears in the folder it belongs to', async () => {
    const { backend, nodes } = build([folderNode('Notes')]);
    const seen = recorder();
    backend.watchFolder('Notes', seen);
    expectEqual(seen.last().entries.length, 0);

    nodes.remoteWrite(fileNode('Notes/Later.md', '# Later'));

    expectEqual(seen.calls.length, 2);
    expectEqual(seen.last().entries.map((entry) => entry.name), ['Later.md']);
    expect(seen.last().entries[0].isMarkdown, 'it should be openable');
  });

  test('a folder listing arrives sorted, like a fetched one', () => {
    const { backend, nodes } = build([folderNode('Notes')]);
    const seen = recorder();
    backend.watchFolder('Notes', seen);

    nodes.remoteWrite(fileNode('Notes/zebra.md', ''));
    nodes.remoteWrite(fileNode('Notes/apple.md', ''));
    nodes.remoteWrite(folderNode('Notes/Archive'));

    expectEqual(
      seen.last().entries.map((entry) => entry.name),
      ['Archive', 'apple.md', 'zebra.md'],
      'folders first, then names in order'
    );
  });

  test('unsubscribing really does stop the delivery', () => {
    const { backend, nodes } = build([folderNode('Notes')]);
    const seen = recorder();
    const stop = backend.watchFolder('Notes', seen);
    const before = seen.calls.length;

    stop();
    nodes.remoteWrite(fileNode('Notes/Ignored.md', ''));

    expectEqual(seen.calls.length, before);
    expectEqual(nodes.watcherCount(), 0, 'nothing should be left attached');
  });

  test('watching a document delivers the same payload as reading it', async () => {
    const { backend } = build([fileNode('Notes.md', '# Notes')]);
    const seen = recorder();
    backend.watchDocument('Notes.md', seen);

    expectEqual(seen.last(), await backend.read('Notes.md'));
  });

  test('a document edited elsewhere arrives with its new text and size', () => {
    const { backend, nodes } = build([fileNode('Notes.md', 'a')]);
    const seen = recorder();
    backend.watchDocument('Notes.md', seen);

    nodes.remoteWrite(fileNode('Notes.md', 'café'));

    expectEqual(seen.last().text, 'café');
    expectEqual(seen.last().size, 5, 'UTF-8 bytes, as everywhere else');
  });

  test('a deleted document arrives as null rather than as an error', () => {
    const { backend, nodes } = build([fileNode('Notes.md', '# Notes')]);
    const seen = recorder();
    backend.watchDocument('Notes.md', seen);

    nodes.remoteDelete('Notes.md');

    expectEqual(seen.last(), null);
  });

  test('something that is not an openable document reports null, and does not throw', () => {
    // A watcher has no caller underneath it to catch a throw, and "there is
    // nothing here to show you" is true of a folder and of a .txt alike.
    const { backend, nodes } = build([folderNode('Notes')]);
    const folderSeen = recorder();
    backend.watchDocument('Notes', folderSeen);
    expectEqual(folderSeen.last(), null);

    nodes.remoteWrite(fileNode('Notes/Readme.txt', 'plain'));
    const textSeen = recorder();
    backend.watchDocument('Notes/Readme.txt', textSeen);
    expectEqual(textSeen.last(), null);
  });

  test('an image uploaded elsewhere becomes resolvable without a reload', async () => {
    const { backend, nodes, assets } = build([
      fileNode('Trip.md', '![](Trip.assets/map.png)'),
      folderNode('Trip.assets'),
    ]);
    await backend.read('Trip.md');
    expectEqual(backend.imageURL('Trip.assets/map.png'), null, 'not there yet');

    const changed = recorder();
    backend.watchAssets('Trip.md', changed);
    const uploadedCalls = changed.calls.length;

    await assets.upload('Trip.assets/map.png', fakeImage('map.png'));
    const uploaded = assetNode('Trip.assets/map.png');
    nodes.remoteWrite(uploaded);

    expectEqual(backend.imageURL('Trip.assets/map.png'), uploaded.url);
    expect(changed.calls.length > uploadedCalls, 'the caller should be told to re-render');
  });

  test('an assets snapshot that changes no URL does not ask for a re-render', () => {
    const { backend, nodes } = build([
      fileNode('Trip.md', ''),
      folderNode('Trip.assets'),
      assetNode('Trip.assets/map.png'),
    ]);
    const changed = recorder();
    backend.watchAssets('Trip.md', changed);
    const settled = changed.calls.length;

    nodes.remoteWrite(assetNode('Trip.assets/map.png'));

    expectEqual(changed.calls.length, settled, 'the same URL is not news');
  });
});

/** The smallest thing `receiveDocumentRevision` will accept. */
function stubModel({
  source = '',
  isDirty = false,
  path = 'Notes.md',
  // Clean means the screen and the server agree, so this follows `source`
  // unless a test says otherwise.
  savedSource = source,
} = {}) {
  return {
    source,
    savedSource,
    isDirty,
    path,
    displayName: 'Notes.md',
    get isUntitled() {
      return this.path === null;
    },
    applied: null,
    detached: false,
    applyRemote(revision) {
      this.applied = revision;
      this.source = revision.text;
      this.savedSource = revision.text;
      this.isDirty = false;
      return true;
    },
    detach() {
      this.detached = true;
      this.path = null;
      this.savedSource = null;
      this.isDirty = true;
    },
  };
}

function receive(model, revision) {
  const events = [];
  const outcome = receiveDocumentRevision({
    model,
    revision,
    onConflict: () => events.push('conflict'),
    onDetached: () => events.push('detached'),
  });
  return { outcome, events };
}

suite('Deciding what to do with a revision', () => {
  test('a clean document takes the new text', () => {
    const model = stubModel({ source: 'old' });
    const { outcome } = receive(model, { text: 'new' });

    expectEqual(outcome, 'applied');
    expectEqual(model.source, 'new');
  });

  test('this browser\u2019s own save, echoing back, changes nothing', () => {
    const model = stubModel({ source: 'same' });
    const { outcome } = receive(model, { text: 'same' });

    expectEqual(outcome, 'ignored');
    expectEqual(model.applied, null, 'nothing should have been re-applied');
  });

  test('unsaved edits are never overwritten', () => {
    // The whole feature is only safe because of this one branch.
    const model = stubModel({
      source: 'my unsaved sentence',
      savedSource: 'what the server has',
      isDirty: true,
    });
    const { outcome, events } = receive(model, { text: 'their version' });

    expectEqual(outcome, 'deferred');
    expectEqual(model.source, 'my unsaved sentence', 'the typing survives');
    expectEqual(model.applied, null);
    expectEqual(events, ['conflict'], 'and the person is told');
  });

  test('an autosave echoing back while typing continues is not a conflict', () => {
    // The common case, and the one that would have made this feature
    // unbearable: autosave writes, the person keeps typing, and a moment later
    // the server repeats what it was just given. The document is legitimately
    // dirty and the incoming text legitimately differs from the screen, but
    // nothing has happened and there is nothing to say.
    const model = stubModel({
      source: 'hello world',
      savedSource: 'hello',
      isDirty: true,
    });
    const { outcome, events } = receive(model, { text: 'hello' });

    expectEqual(outcome, 'ignored');
    expectEqual(model.source, 'hello world');
    expectEqual(events, [], 'no conflict warning for our own echo');
  });

  test('a revision matching the saved text is ignored even when dirty', () => {
    // Undone back to the saved text, or the same edit made in both places.
    // Either way the screen and the server already agree.
    const model = stubModel({ source: 'same', isDirty: true });
    const { outcome, events } = receive(model, { text: 'same' });

    expectEqual(outcome, 'ignored');
    expectEqual(model.applied, null);
    expectEqual(events, []);
  });

  test('a document deleted elsewhere is detached, keeping the text on screen', () => {
    const model = stubModel({ source: 'work in progress' });
    const { outcome, events } = receive(model, null);

    expectEqual(outcome, 'detached');
    expect(model.detached, 'the file is gone');
    expectEqual(model.source, 'work in progress', 'the work is not');
    expectEqual(events, ['detached']);
  });

  test('a second notification about the same deletion does nothing', () => {
    const model = stubModel({ source: 'work in progress' });
    receive(model, null);
    const again = receive(model, null);

    expectEqual(again.outcome, 'ignored');
    expectEqual(again.events, [], 'and does not say it twice');
  });
});

suite('Adopting a revision into the document model', () => {
  test('the previous text becomes an undo step', () => {
    // Otherwise an arriving revision would be the one change in the editor
    // that cannot be taken back.
    const model = new MarkdownDocumentModel();
    model.source = 'mine';
    model.savedSource = 'mine';

    expect(model.applyRemote({ text: 'theirs' }), 'it should report a change');
    expectEqual(model.source, 'theirs');
    expect(model.canUndo, 'and it should be undoable');

    model.undo();
    expectEqual(model.source, 'mine');
    expect(model.isDirty, 'undoing back to my version leaves it to be saved');
  });

  test('the adopted text counts as saved, because it came from the server', () => {
    const model = new MarkdownDocumentModel();
    model.applyRemote({ text: 'from elsewhere' });

    expectEqual(model.isDirty, false);
    expectEqual(model.savedSource, 'from elsewhere');
  });

  test('a caret past the end of shorter incoming text is pulled back', () => {
    const model = new MarkdownDocumentModel();
    model.source = 'a long paragraph';
    model.savedSource = model.source;
    model.selection = makeRange(14, 2);

    model.applyRemote({ text: 'short' });

    expectEqual(model.selection.location <= 5, true, 'inside the new text');
    expectEqual(model.selection.location + model.selection.length <= 5, true);
  });

  test('text that is already current reports no change', () => {
    const model = new MarkdownDocumentModel();
    model.source = 'same';
    model.savedSource = 'same';

    expectEqual(model.applyRemote({ text: 'same' }), false);
    expectEqual(model.canUndo, false, 'and adds no empty undo step');
  });

  test('a detached document that comes back is attached again', () => {
    // Deleted on another device, then restored there: it has a file again.
    const model = new MarkdownDocumentModel();
    model.source = 'text';
    model.savedSource = 'text';
    model.path = 'Notes.md';
    model.detach();
    expect(model.isUntitled && model.isDirty, 'detached, as WF-9 requires');

    model.applyRemote({ text: 'text', path: 'Notes.md', name: 'Notes.md' });

    expectEqual(model.path, 'Notes.md');
    expectEqual(model.isDirty, false);
    expectEqual(model.detachedPath, null);
  });
});

/** An explorer with nothing in it but the two things `live.js` uses. */
function stubExplorer(folders = ['']) {
  return {
    folders,
    listings: [],
    onFoldersChanged: () => {},
    visibleFolders() {
      return this.folders;
    },
    applyLiveListing(path, entries) {
      this.listings.push({ path, entries });
      // The real explorer re-renders here, and rendering is what tells the
      // coordinator which folders are visible. Modelling that is the only way
      // a test can catch a subscription loop.
      if (this.rerenders) this.onFoldersChanged();
    },
    show(folders) {
      this.folders = folders;
      this.onFoldersChanged();
    },
  };
}

suite('Keeping the watchers pointed at what is on screen', () => {
  test('one watcher per visible folder, and none for a folder that closed', () => {
    const { backend, nodes } = build([
      folderNode('Notes'),
      folderNode('Trips'),
    ]);
    setBackend(backend);
    const explorer = stubExplorer(['', 'Notes']);
    const model = new MarkdownDocumentModel();

    const stop = startLiveUpdates({
      model,
      explorer,
      notify: () => {},
      onDocumentChanged: () => {},
    });
    expectEqual(nodes.watcherCount(), 2);

    explorer.show(['', 'Trips']);
    expectEqual(nodes.watcherCount(), 2, 'Notes swapped for Trips, not added to');

    nodes.remoteWrite(fileNode('Notes/Ignored.md', ''));
    expectEqual(explorer.listings.length, 0, 'a closed folder is not pushed');

    nodes.remoteWrite(fileNode('Trips/Kyoto.md', ''));
    expectEqual(explorer.listings.at(-1).path, 'Trips');

    stop();
    expectEqual(nodes.watcherCount(), 0, 'stopping releases everything');
    setBackend(backend);
  });

  test('attaching a watcher does not re-render what the sidebar just drew', () => {
    // Firestore hands over the current contents the moment a listener attaches.
    // Acting on that would be a pointless re-render — and since rendering is
    // what triggers this sync, a loop.
    const { backend, nodes } = build([folderNode('Notes')]);
    setBackend(backend);
    const explorer = stubExplorer(['Notes']);

    const stop = startLiveUpdates({
      model: new MarkdownDocumentModel(),
      explorer,
      notify: () => {},
      onDocumentChanged: () => {},
    });

    expectEqual(explorer.listings.length, 0, 'the first snapshot is not news');

    nodes.remoteWrite(fileNode('Notes/Real.md', ''));
    expectEqual(explorer.listings.length, 1, 'a real change is');
    stop();
  });

  test('the document watcher follows the document that is open', () => {
    const { backend, nodes } = build([fileNode('One.md', '1'), fileNode('Two.md', '2')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    const changed = [];

    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: () => {},
      onDocumentChanged: () => changed.push(model.source),
    });

    model.path = 'One.md';
    model.source = '1';
    model.savedSource = '1';
    model.notify();

    nodes.remoteWrite(fileNode('One.md', '1 edited elsewhere'));
    expectEqual(model.source, '1 edited elsewhere');

    // Open the other document: the first one must stop being followed.
    model.path = 'Two.md';
    model.source = '2';
    model.savedSource = '2';
    model.notify();

    nodes.remoteWrite(fileNode('One.md', 'changed again'));
    expectEqual(model.source, '2', 'a closed document cannot write over the open one');

    nodes.remoteWrite(fileNode('Two.md', '2 edited elsewhere'));
    expectEqual(model.source, '2 edited elsewhere');
    expectEqual(changed.length, 2, 'each adoption asks for a re-render');
    stop();
  });

  test('a stopped coordinator watches nothing, whatever happens next', () => {
    const { backend, nodes } = build([folderNode('Notes'), fileNode('Notes.md', 'x')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    model.path = 'Notes.md';
    const explorer = stubExplorer(['', 'Notes']);

    const stop = startLiveUpdates({
      model,
      explorer,
      notify: () => {},
      onDocumentChanged: () => {},
    });
    stop();

    expectEqual(nodes.watcherCount(), 0);
    explorer.show(['', 'Notes', 'Trips']);
    expectEqual(nodes.watcherCount(), 0, 'a late render must not re-subscribe');
  });

  test('a sidebar that re-renders on every push does not pile up watchers', () => {
    // Rendering asks which folders are visible, and a push causes a render, so
    // subscribing has to be safe to re-enter. If it is not, this recurses
    // until the stack runs out.
    const { backend, nodes } = build([folderNode('Notes')]);
    setBackend(backend);
    const explorer = stubExplorer(['', 'Notes']);
    explorer.rerenders = true;

    const stop = startLiveUpdates({
      model: new MarkdownDocumentModel(),
      explorer,
      notify: () => {},
      onDocumentChanged: () => {},
    });
    expectEqual(nodes.watcherCount(), 2, 'one each, not one per render');

    nodes.remoteWrite(fileNode('Notes/New.md', ''));
    expectEqual(nodes.watcherCount(), 2, 'still one each after a push');
    expectEqual(explorer.listings.length, 1, 'and the push was applied once');
    stop();
    expectEqual(nodes.watcherCount(), 0);
  });

  test('a renamed document with unsaved edits is not reported as changed elsewhere', () => {
    // WF-9 keeps unsaved edits through a rename, so the watcher re-attaches
    // under the new path while the document is dirty. The contents it is
    // handed on attach are the older saved text — which is not news from
    // another device, and must not be announced as if it were.
    const { backend } = build([fileNode('Notes.md', 'saved text')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    const messages = [];

    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: (message) => messages.push(message),
      onDocumentChanged: () => {},
    });

    model.path = 'Notes.md';
    model.source = 'my unsaved sentence';
    model.savedSource = 'saved text';
    model.isDirty = true;
    model.notify();

    expectEqual(messages, [], 'attaching is not an event worth reporting');
    expectEqual(model.source, 'my unsaved sentence', 'and the edits are untouched');
    stop();
  });

  test('but a real change found on attach is still reported', () => {
    // The other half of the same situation, and the reason the attach
    // snapshot is read rather than skipped: if another device changed the
    // document while this one was elsewhere, that first snapshot is the only
    // notice there will ever be. Skipping it to silence the case above would
    // have thrown this one away with it.
    const { backend } = build([fileNode('Notes.md', 'what they wrote')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    const messages = [];
    const conflicts = [];

    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: (message) => messages.push(message),
      onConflict: (revision) => conflicts.push(revision),
      onDocumentChanged: () => {},
    });

    model.path = 'Notes.md';
    model.source = 'my unsaved sentence';
    model.savedSource = 'what I last saved';
    model.isDirty = true;
    model.notify();

    // Handed over rather than announced and dropped (WC-10): this is the only
    // copy of what the other device wrote, and a notice nobody can act on is
    // worse than none.
    expectEqual(conflicts.length, 1, 'the clash is reported');
    expectEqual(conflicts[0].text, 'what they wrote', 'with the text they wrote');
    expectEqual(model.source, 'my unsaved sentence', 'and still nothing is lost');
    stop();
  });

  test('a revision that arrives after its document closed is discarded', () => {
    // A `onSnapshot` unsubscribe stops delivery, so this should be
    // unreachable — which is exactly why it is worth pinning down. The
    // listener is captured and called by hand here, because the only honest
    // way to test a guard against a late delivery is to deliver one late.
    let deliver = null;
    setBackend({
      watchFolder: () => () => {},
      watchAssets: () => () => {},
      watchDocument: (path, listener) => {
        deliver = listener;
        return () => {};
      },
    });

    const model = new MarkdownDocumentModel();
    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: () => {},
      onDocumentChanged: () => {},
    });

    model.path = 'One.md';
    model.source = 'one';
    model.savedSource = 'one';
    model.notify();
    const staleListener = deliver;

    // The user opens something else before the revision lands.
    model.path = 'Two.md';
    model.source = 'two';
    model.savedSource = 'two';
    model.notify();

    staleListener({ text: 'a late revision of One.md' });

    expectEqual(model.source, 'two', 'the open document is not written over');
    stop();
  });
});

suite('What a save records as saved', () => {
  // `savedSource` is what tells a live update apart from this browser's own
  // echo, so it has to be the text that actually went to the server — not the
  // text on screen when the reply came back. At autosave speed those differ
  // whenever someone keeps typing, which is most of the time.

  /** A backend whose write can be held open, so typing can land mid-flight. */
  function slowBackend(text = 'hello') {
    const writes = [];
    let release = null;
    setBackend({
      read: async (path) => ({ path, name: path.split('/').pop(), text, hasByteOrderMark: false }),
      write: async (path, written) => {
        writes.push({ path, text: written });
        await new Promise((resolve) => {
          release = resolve;
        });
        return { path, name: path.split('/').pop() };
      },
    });
    return { writes, release: () => release() };
  }

  test('records the text it sent, not the text typed while it was in flight', async () => {
    const backend = slowBackend();
    const model = new MarkdownDocumentModel();
    await model.open('Notes.md');

    model.source = 'hello';
    model.isDirty = true;
    const saving = model.save();

    // The reply has not arrived yet, and the person is still typing.
    model.source = 'hello world';
    backend.release();
    await saving;

    expectEqual(backend.writes[0].text, 'hello', 'the server got the old text');
    expectEqual(model.savedSource, 'hello', 'and that is what is recorded');
    expectEqual(model.source, 'hello world', 'the newer typing is untouched');
    expect(model.isDirty, 'and it is still unsaved, because it is');

    model.cancelAutosave();
    setBackend(null);
  });

  test('a save with nothing typed during it leaves the document clean', async () => {
    const backend = slowBackend();
    const model = new MarkdownDocumentModel();
    await model.open('Notes.md');

    model.source = 'hello world';
    model.isDirty = true;
    const saving = model.save();
    backend.release();
    await saving;

    expectEqual(model.savedSource, 'hello world');
    expectEqual(model.isDirty, false);
    setBackend(null);
  });
});

// WC-9 / WC-10. Watchers only hear what happens while somebody is listening,
// and there are two ways to have not been: a backend that pushes nothing (the
// local one, WC-7), and a tab the browser suspended while it was in the
// background. Coming back is when the file is most likely to have moved on.
suite('Catching up on returning to the tab', () => {
  /** Stands in for the browser's visibility and focus events. */
  function returnTrigger() {
    let handler = null;
    const observe = (fn) => {
      handler = fn;
      return () => {
        handler = null;
      };
    };
    observe.returnToTab = () => handler?.();
    observe.isListening = () => handler !== null;
    return observe;
  }

  async function settle() {
    await new Promise((resolve) => setTimeout(resolve, 0));
    await new Promise((resolve) => setTimeout(resolve, 0));
  }

  test('a change made while the tab was away is found on returning to it', async () => {
    const { nodes, backend } = build([fileNode('Notes.md', 'as I left it')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    await model.open('Notes.md');

    const messages = [];
    const observe = returnTrigger();
    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: (message) => messages.push(message),
      onDocumentChanged: () => {},
      observeReturn: observe,
    });

    // Somebody else writes while this tab is in the background. No listener
    // fires: this stands for the local backend, which pushes nothing at all.
    nodes.silentWrite(fileNode('Notes.md', 'changed while I was away'));

    observe.returnToTab();
    await settle();

    expectEqual(model.source, 'changed while I was away', 'the newest text is shown');
    expectEqual(messages.length, 1, 'and it is said out loud');
    stop();
    setBackend(null);
  });

  test('returning to a tab that is already up to date says nothing', async () => {
    const { backend } = build([fileNode('Notes.md', 'as I left it')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    await model.open('Notes.md');

    const messages = [];
    const observe = returnTrigger();
    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: (message) => messages.push(message),
      onDocumentChanged: () => {},
      observeReturn: observe,
    });

    observe.returnToTab();
    await settle();

    expectEqual(messages, [], 'switching tabs is not an event in itself');
    stop();
    setBackend(null);
  });

  test('unsaved edits are handed the newer version rather than losing it', async () => {
    const { nodes, backend } = build([fileNode('Notes.md', 'as I left it')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    await model.open('Notes.md');

    const conflicts = [];
    const observe = returnTrigger();
    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: () => {},
      onConflict: (revision) => conflicts.push(revision),
      onDocumentChanged: () => {},
      observeReturn: observe,
    });

    model.source = 'what I was typing';
    model.isDirty = true;
    nodes.silentWrite(fileNode('Notes.md', 'what they wrote'));

    observe.returnToTab();
    await settle();

    expectEqual(model.source, 'what I was typing', 'nothing on screen is touched');
    expectEqual(conflicts.length, 1, 'and the other version is handed over');
    expectEqual(conflicts[0].text, 'what they wrote', 'intact, so it can be shown');
    stop();
    setBackend(null);
  });

  test('a document opened since the request went out is not overwritten', async () => {
    const { backend } = build([
      fileNode('Notes.md', 'notes as they are on the server'),
      fileNode('Other.md', 'a different document'),
    ]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    await model.open('Notes.md');

    const observe = returnTrigger();
    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: () => {},
      onDocumentChanged: () => {},
      observeReturn: observe,
    });

    // The read is in flight for Notes.md when something else is opened.
    const revalidating = stop.revalidate();
    await model.open('Other.md');
    await revalidating;
    await settle();

    expectEqual(model.source, 'a different document', 'the open document stands');
    stop();
    setBackend(null);
  });

  test('a backend that cannot answer is not an interruption', async () => {
    setBackend({
      watchFolder: () => () => {},
      watchAssets: () => () => {},
      watchDocument: () => () => {},
      read: async () => {
        throw new Error('offline');
      },
    });
    const model = new MarkdownDocumentModel();
    model.path = 'Notes.md';
    model.source = 'mine';
    model.savedSource = 'mine';

    const messages = [];
    const observe = returnTrigger();
    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: (message) => messages.push(message),
      onDocumentChanged: () => {},
      observeReturn: observe,
    });

    expectEqual(await stop.revalidate(), 'ignored', 'the failure is swallowed');
    expectEqual(messages, [], 'and nobody is interrupted over it');
    expectEqual(model.source, 'mine', 'the document is left alone');
    stop();
    setBackend(null);
  });

  test('stopping unsubscribes from the return events', () => {
    setBackend(build().backend);
    const model = new MarkdownDocumentModel();
    const observe = returnTrigger();
    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: () => {},
      onDocumentChanged: () => {},
      observeReturn: observe,
    });

    expect(observe.isListening(), 'it listens while running');
    stop();
    expectEqual(observe.isListening(), false, 'and lets go when it stops');
    setBackend(null);
  });

  test('a revalidation after stopping does nothing', async () => {
    const { nodes, backend } = build([fileNode('Notes.md', 'as I left it')]);
    setBackend(backend);
    const model = new MarkdownDocumentModel();
    await model.open('Notes.md');

    const stop = startLiveUpdates({
      model,
      explorer: stubExplorer([]),
      notify: () => {},
      onDocumentChanged: () => {},
      observeReturn: returnTrigger(),
    });
    stop();

    nodes.silentWrite(fileNode('Notes.md', 'changed after we stopped'));
    expectEqual(await stop.revalidate(), 'ignored');
    expectEqual(model.source, 'as I left it', 'a stopped coordinator is stopped');
    setBackend(null);
  });
});
