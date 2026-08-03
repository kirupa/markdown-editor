// Application wiring.
//
// Everything user-visible is assembled here: the two editing surfaces, the
// mode switch, the command table shared by the toolbar and menus, image
// import, the dividers, and scroll/selection synchronization.

import { api, ApiError } from './api.js';
import { MarkdownDocumentModel } from './document.js';
import { makeRange, maxRange } from './core/range.js';
import { renderMarkdown } from './core/render-model.js';
import {
  InlineStyle,
  ListStyle,
  applyHeading,
  insertHorizontalRule,
  insertLink,
  toggleInline,
  toggleList,
  toggleQuote,
  wrapCodeBlock,
} from './core/formatting.js';
import { renderInto } from './ui/renderer.js';
import { renderSourceInto } from './ui/source-renderer.js';
import { EditorSurface } from './ui/editor-surface.js';
import { positionForOffset } from './dom-text.js';
import { Explorer } from './ui/explorer.js';
import { buildToolbar } from './ui/toolbar.js';
import { buildMenus } from './ui/menus.js';
import { WelcomeScreen, recentDocuments } from './ui/welcome.js';
import { confirmAction, confirmDiscard, showError, showPrompt } from './ui/dialogs.js';
import { theme, openThemePopover } from './ui/theme.js';

const MODE_KEY = 'markdown-editor.mode';
const SIDEBAR_KEY = 'markdown-editor.sidebarVisible';
const SIDEBAR_WIDTH_KEY = 'markdown-editor.sidebarWidth';
const PREVIEW_WIDTH_KEY = 'markdown-editor.previewWidth';

const element = (id) => document.getElementById(id);

theme.apply();

const model = new MarkdownDocumentModel();
let renderModel = renderMarkdown('');
let renderModelSource = '';

/** Rebuilds the render model only when the source it was built from changed. */
function modelFor(source) {
  if (renderModelSource !== source) {
    renderModel = renderMarkdown(source);
    renderModelSource = source;
  }
  return renderModel;
}
let mode = localStorage.getItem(MODE_KEY) ?? 'split';
let sidebarVisible = localStorage.getItem(SIDEBAR_KEY) !== 'false';
let config = { workspaceName: 'Workspace', imageExtensions: [] };

/**
 * The rendered pane's projection. Every mapping goes through the render model,
 * which is rebuilt whenever the source changes — the model is the only thing
 * that knows where a rendered character came from.
 */
const richProjection = {
  render: (source) => renderInto(element('richSurface'), modelFor(source), resolveImageURL),
  textFor: (source) => modelFor(source).text,
  toSource: (source, range) => modelFor(source).sourceRange(range),
  toSurface: (source, range) => modelFor(source).renderedRange(range),
};

/** The raw pane shows the source itself, so every mapping is the identity. */
const sourceProjection = {
  render: (source) => renderSourceInto(element('sourceSurface'), source, modelFor(source)),
  textFor: (source) => source,
  toSource: (_source, range) => range,
  toSurface: (_source, range) => range,
};

const richSurface = new EditorSurface(element('richSurface'), richProjection, model);
const sourceSurface = new EditorSurface(element('sourceSurface'), sourceProjection, model);

const explorer = new Explorer({
  tree: element('explorerTree'),
  pathButton: element('explorerPath'),
  pathLabel: element('explorerPathLabel'),
  refreshButton: element('explorerRefresh'),
  revealButton: element('explorerReveal'),
});

const welcome = new WelcomeScreen(element('welcome'), {
  newDocument: () => commands.newDocument(),
  open: () => commands.open(),
  openPath: (path) => openDocument(path),
});

// In Split, a command applies to whichever pane the user was last editing.
// Tracking that explicitly means a control that steals focus on click cannot
// silently redirect the command to the other pane (F-10).
let lastFocused = richSurface;
for (const surface of [richSurface, sourceSurface]) {
  surface.element.addEventListener('focus', () => {
    lastFocused = surface;
  });
}

/** The surface a formatting command should act on. */
function activeSurface() {
  if (mode === 'source') return sourceSurface;
  if (mode === 'rich') return richSurface;
  return lastFocused;
}

function currentSelection() {
  return activeSurface().currentSourceSelection() ?? model.selection;
}

/** Applies a `{text, selection}` result from the shared formatting layer. */
function applyResult(result) {
  const surface = activeSurface();
  model.edit(result.text, result.selection);
  surface.focus();
  surface.applySelection(model.source, model.selection);
}

function resolveImageURL(destination) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(destination)) return destination;
  if (!model.path) return null;
  const folder = model.path.includes('/')
    ? model.path.slice(0, model.path.lastIndexOf('/'))
    : '';
  const relative = destination.split('/').map(decodeSegment).join('/');
  const joined = folder ? `${folder}/${relative}` : relative;
  return `api.php?action=asset&path=${encodeURIComponent(joined)}`;
}

function decodeSegment(segment) {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

const commands = {
  inline(name) {
    applyResult(toggleInline(InlineStyle[name], model.source, currentSelection()));
  },
  heading(level) {
    applyResult(applyHeading(level, model.source, currentSelection()));
  },
  list(name) {
    applyResult(toggleList(ListStyle[name], model.source, currentSelection()));
  },
  quote() {
    applyResult(toggleQuote(model.source, currentSelection()));
  },
  codeBlock() {
    applyResult(wrapCodeBlock(model.source, currentSelection()));
  },
  horizontalRule() {
    applyResult(insertHorizontalRule(model.source, currentSelection()));
  },
  async link() {
    const destination = await showPrompt({
      title: 'Insert Link',
      message: 'Enter the URL this link should point to.',
      value: 'https://',
      confirmLabel: 'Insert',
    });
    if (destination === null) return;
    applyResult(insertLink(destination, model.source, currentSelection()));
  },
  image: () => pickImage(),
  undo: () => model.undo(),
  redo: () => model.redo(),
  selectAll() {
    const surface = activeSurface();
    surface.focus();
    model.setSelection(makeRange(0, model.source.length));
    surface.applySelection(model.source, model.selection);
  },
  newDocument: () => newDocument(),
  open: () => {
    sidebarVisible = true;
    applySidebarVisibility();
    element('explorerTree').focus();
  },
  save: () => saveDocument(),
  saveAs: () => saveDocument({ forcePrompt: true }),
  close: () => closeDocument(),
  showWelcome: () => welcome.show({ dismissable: true }),
  setMode: (next) => setMode(next),
  toggleSidebar() {
    sidebarVisible = !sidebarVisible;
    applySidebarVisibility();
  },
  customizeTheme(anchor) {
    openThemePopover(anchor ?? element('toolbar').querySelector('.me-tool-group:last-child button'), () => {
      // Re-rendering picks up theme-dependent inline styles in one pass.
      refreshSurfaces({ force: true });
    });
  },
};

const toolbar = buildToolbar(element('toolbar'), commands);
buildMenus(element('menubar'), commands, {
  canUndo: () => model.canUndo,
  canRedo: () => model.canRedo,
  mode: () => mode,
  sidebarVisible: () => sidebarVisible,
});

/**
 * F-11: the toolbar mirrors what is active where the caret sits. The render
 * model already knows which spans cover a source offset, so this is a lookup
 * rather than a second parser.
 */
function refreshActiveStyles() {
  const selection = model.selection;
  const rendered = modelFor(model.source);
  const inline = new Set();
  let list = null;
  let quote = false;
  let heading = 0;

  for (const span of rendered.spans) {
    const start = span.sourceRange.location;
    const end = start + span.sourceRange.length;
    if (selection.location < start || selection.location > end) continue;
    const kind = span.style.kind;
    if (kind === 'heading') heading = span.style.level;
    else if (kind === 'quote') quote = true;
    else if (kind === 'bulletedList') list = 'bulleted';
    else if (kind === 'numberedList') list = 'numbered';
    else if (kind === 'taskList') list = 'task';
    else if (
      kind === 'bold' ||
      kind === 'italic' ||
      kind === 'underline' ||
      kind === 'strikethrough' ||
      kind === 'inlineCode'
    ) {
      inline.add(kind);
    }
  }
  toolbar.setActiveStyles({ inline, list, quote, heading });
}

function refreshSurfaces(options = {}) {
  richSurface.sync(model.source, model.selection, options);
  sourceSurface.sync(model.source, model.selection, options);
}

model.addEventListener('change', () => {
  refreshSurfaces();
  refreshActiveStyles();
  updateStatus();
});
model.addEventListener('selection', refreshActiveStyles);

// E-16: moving the caret in one pane moves it in the other, so Side by Side
// always shows the same place twice.
function mirrorSelection(source) {
  refreshActiveStyles();
  if (mode !== 'split') return;
  const other = source === richSurface ? sourceSurface : richSurface;
  const range = other.projection.toSurface(model.source, model.selection);
  const node = other.element;
  // Only scroll — stealing the DOM selection would steal focus with it.
  const position = positionForOffset(node, range.location);
  if (!position) return;
  const probe = document.createRange();
  probe.setStart(position.node, position.offset);
  probe.collapse(true);
  const rect = probe.getBoundingClientRect();
  const bounds = node.parentElement.getBoundingClientRect();
  if (rect.top < bounds.top || rect.bottom > bounds.bottom) {
    node.parentElement.scrollTop += rect.top - bounds.top - bounds.height / 3;
  }
}

richSurface.onSelectionChange = () => mirrorSelection(richSurface);
sourceSurface.onSelectionChange = () => mirrorSelection(sourceSurface);
model.addEventListener('open', () => {
  richSurface.renderedSource = null;
  sourceSurface.renderedSource = null;
  refreshSurfaces({ force: true });
});
model.addEventListener('autosaved', () => flashStatus('Autosaved'));
model.addEventListener('saved', () => flashStatus('Saved'));
model.addEventListener('error', (event) => showError(event.detail));

function updateStatus() {
  const folder = model.path?.includes('/')
    ? model.path.slice(0, model.path.lastIndexOf('/'))
    : '';
  const name = model.displayName + (model.isDirty ? ' — Edited' : '');
  element('statusDocument').textContent = folder ? `${name} · ${folder}` : name;
}

let statusTimer = null;
function flashStatus(message) {
  const label = element('statusSaved');
  label.textContent = message;
  if (statusTimer) window.clearTimeout(statusTimer);
  statusTimer = window.setTimeout(() => {
    label.textContent = '';
  }, 2000);
  updateStatus();
}

function setMode(next) {
  mode = next;
  localStorage.setItem(MODE_KEY, next);
  element('editor').dataset.mode = next;
  element('richPane').hidden = next === 'source';
  element('sourcePane').hidden = next === 'rich';
  element('paneDivider').hidden = next !== 'split';
  toolbar.setMode(next);
  refreshSurfaces({ force: true });
}

function applySidebarVisibility() {
  localStorage.setItem(SIDEBAR_KEY, sidebarVisible ? 'true' : 'false');
  element('sidebar').hidden = !sidebarVisible;
  element('sidebarDivider').hidden = !sidebarVisible;
}

/**
 * Gates any action that would abandon unsaved edits (PRD D-6). Only an explicit
 * "Don't Save" or a save that actually succeeded may proceed; cancelling — or
 * dismissing the prompt with Escape, which resolves null — must not.
 */
async function guardUnsaved() {
  if (!model.isDirty) return true;
  const choice = await confirmDiscard(model.displayName);
  if (choice === 'discard') return true;
  if (choice !== 'save') return false;
  try {
    await saveDocument();
  } catch {
    return false;
  }
  // A cancelled Save As leaves the document dirty and untitled, so the caller
  // must not continue either.
  return !model.isDirty;
}

async function newDocument() {
  if (!(await guardUnsaved())) return;
  model.reset();
  welcome.hide();
  setMode(mode);
  richSurface.focus();
  updateStatus();
}

async function openDocument(path) {
  if (!(await guardUnsaved())) return;
  try {
    await model.open(path);
    recentDocuments.note(model.path);
    welcome.hide();
    explorer.select(model.path);
    updateStatus();
    activeSurface().focus();
  } catch (error) {
    if (error instanceof ApiError) recentDocuments.forget(path);
    showError(error);
  }
}

async function saveDocument({ forcePrompt = false } = {}) {
  let target = model.path;
  if (forcePrompt || !target) {
    const suggestion = target ?? `${model.displayName}.md`;
    const entered = await showPrompt({
      title: forcePrompt ? 'Save As' : 'Save',
      message: 'Enter a workspace-relative path, ending in .md or .markdown.',
      value: suggestion,
      confirmLabel: 'Save',
    });
    if (entered === null) return;
    target = entered.trim();
    if (target === '') return;
  }
  try {
    await model.save({ path: target });
    recentDocuments.note(model.path);
    await explorer.reload();
    explorer.select(model.path);
    updateStatus();
  } catch (error) {
    showError(error);
    throw error;
  }
}

async function closeDocument() {
  if (!(await guardUnsaved())) return;
  model.reset();
  welcome.show();
  updateStatus();
}

// ---------------------------------------------------------------- images

const imageInput = document.createElement('input');
imageInput.type = 'file';
imageInput.accept = 'image/*';
imageInput.multiple = true;
imageInput.style.display = 'none';
document.body.append(imageInput);
imageInput.addEventListener('change', () => {
  const files = Array.from(imageInput.files ?? []);
  imageInput.value = '';
  if (files.length > 0) importImages(files);
});

function pickImage() {
  imageInput.click();
}

/**
 * I-1 … I-18: the file is copied into `<stem>.assets/` beside the document and
 * a relative Markdown reference is inserted at the caret. The document must
 * already have a location, because the assets folder is defined relative to it.
 */
async function importImages(files) {
  if (model.isUntitled) {
    // Assets live beside the document, so there is nowhere to put them yet.
    // Offer the step that unblocks the import rather than just refusing.
    const save = await confirmAction({
      title: 'Save the document before adding an image.',
      message:
        'Images are copied into a folder beside the Markdown file, so the document needs a location first.',
      confirmLabel: 'Save…',
    });
    if (!save) return;
    try {
      await saveDocument();
    } catch {
      return;
    }
    if (model.isUntitled) return;
  }
  for (const file of files) {
    try {
      const result = await api.uploadImage(model.path, file);
      const selection = currentSelection();
      const snippet = result.markdownReference;
      const newSource =
        model.source.slice(0, selection.location) +
        snippet +
        model.source.slice(maxRange(selection));
      model.edit(newSource, makeRange(selection.location + snippet.length, 0));
    } catch (error) {
      showError(error);
      return;
    }
  }
  activeSurface().focus();
}

richSurface.onPasteFiles = importImages;
sourceSurface.onPasteFiles = importImages;

for (const surface of [element('richSurface'), element('sourceSurface')]) {
  surface.addEventListener('dragover', (event) => {
    if (!event.dataTransfer?.types.includes('Files')) return;
    event.preventDefault();
    surface.classList.add('is-drop-target');
  });
  surface.addEventListener('dragleave', () => surface.classList.remove('is-drop-target'));
  surface.addEventListener('drop', (event) => {
    const files = Array.from(event.dataTransfer?.files ?? []).filter((file) =>
      file.type.startsWith('image/')
    );
    if (files.length === 0) return;
    event.preventDefault();
    surface.classList.remove('is-drop-target');
    placeCaretAt(surface, event.clientX, event.clientY);
    importImages(files);
  });
}

/**
 * Puts the caret where the image was dropped, so it lands where the author
 * pointed rather than wherever the caret happened to be (PRD WI-9).
 */
function placeCaretAt(surfaceElement, x, y) {
  surfaceElement.focus();
  const range = caretRangeAt(surfaceElement, x, y) ?? endOfBlockAt(surfaceElement, y);
  if (range === null) return;
  range.collapse(true);
  const selection = getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

function caretRangeAt(surfaceElement, x, y) {
  if (typeof document.caretPositionFromPoint === 'function') {
    const position = document.caretPositionFromPoint(x, y);
    if (position && surfaceElement.contains(position.offsetNode)) {
      const range = document.createRange();
      range.setStart(position.offsetNode, position.offset);
      return range;
    }
    return null;
  }
  if (typeof document.caretRangeFromPoint === 'function') {
    const found = document.caretRangeFromPoint(x, y);
    if (found && surfaceElement.contains(found.startContainer)) return found;
  }
  return null;
}

/**
 * Dropping in the empty space beside a line is a normal gesture, and the
 * browser reports no caret position there. Fall back to the end of whichever
 * line the pointer is level with.
 */
function endOfBlockAt(surfaceElement, y) {
  for (const block of surfaceElement.children) {
    const box = block.getBoundingClientRect();
    if (y < box.top || y > box.bottom) continue;
    const range = document.createRange();
    range.selectNodeContents(block);
    range.collapse(false);
    return range;
  }
  return null;
}

// --------------------------------------------------------------- dividers

function installDivider(divider, onDrag) {
  let active = false;
  divider.addEventListener('pointerdown', (event) => {
    active = true;
    divider.setPointerCapture(event.pointerId);
    divider.classList.add('is-dragging');
  });
  divider.addEventListener('pointermove', (event) => {
    if (active) onDrag(event.clientX);
  });
  const stop = (event) => {
    if (!active) return;
    active = false;
    divider.releasePointerCapture(event.pointerId);
    divider.classList.remove('is-dragging');
  };
  divider.addEventListener('pointerup', stop);
  divider.addEventListener('pointercancel', stop);
}

installDivider(element('sidebarDivider'), (clientX) => {
  const width = Math.min(480, Math.max(160, clientX));
  document.documentElement.style.setProperty('--me-sidebar-width', `${width}px`);
  localStorage.setItem(SIDEBAR_WIDTH_KEY, String(width));
});

// L-9: the preview keeps a usable measure no matter how far the gripper drags.
installDivider(element('paneDivider'), (clientX) => {
  const editor = element('editor').getBoundingClientRect();
  const width = Math.round(
    Math.min(Math.max(320, editor.width - 260), Math.max(320, clientX - editor.left))
  );
  document.documentElement.style.setProperty('--me-preview-width', `${width}px`);
  localStorage.setItem(PREVIEW_WIDTH_KEY, String(width));
});

// ------------------------------------------------------------ scroll sync

let syncingScroll = false;
function linkScroll(from, to) {
  from.addEventListener('scroll', () => {
    if (mode !== 'split' || syncingScroll) return;
    syncingScroll = true;
    const range = from.scrollHeight - from.clientHeight;
    const fraction = range > 0 ? from.scrollTop / range : 0;
    const targetRange = to.scrollHeight - to.clientHeight;
    to.scrollTop = fraction * Math.max(0, targetRange);
    // Releasing on the next frame keeps the mirrored scroll from echoing back.
    requestAnimationFrame(() => {
      syncingScroll = false;
    });
  });
}
linkScroll(element('richPane'), element('sourcePane'));
linkScroll(element('sourcePane'), element('richPane'));

// ---------------------------------------------------------------- startup

window.addEventListener('beforeunload', (event) => {
  if (!model.isDirty) return;
  event.preventDefault();
  event.returnValue = '';
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'hidden') model.flushAutosave().catch(() => {});
});

explorer.onOpenFile = (item) => {
  if (!item.isMarkdown) {
    showError(
      new ApiError(
        `“${item.name}” is not a Markdown document.`,
        'Markdown Editor opens files with a .md or .markdown extension.'
      )
    );
    return;
  }
  openDocument(item.path);
};

explorer.onRevealRequested = () => {
  if (model.path) explorer.reveal(model.path);
};

async function start() {
  const storedWidth = localStorage.getItem(SIDEBAR_WIDTH_KEY);
  if (storedWidth) {
    document.documentElement.style.setProperty('--me-sidebar-width', `${storedWidth}px`);
  }
  const storedPreview = localStorage.getItem(PREVIEW_WIDTH_KEY);
  if (storedPreview) {
    document.documentElement.style.setProperty('--me-preview-width', `${storedPreview}px`);
  }

  setMode(mode);
  applySidebarVisibility();
  element('app').hidden = false;

  try {
    config = await api.config();
    welcome.workspaceName = config.workspaceName;
    explorer.rootName = config.workspaceName;
    await explorer.setRoot('');
  } catch (error) {
    showError(error);
  }

  model.reset();

  // W-1: honor an explicit ?path= first, then the launch preference.
  const requested = new URLSearchParams(window.location.search).get('path');
  if (requested) {
    await openDocument(requested);
  } else if (recentDocuments.showAtLaunch) {
    welcome.show();
  } else {
    richSurface.focus();
  }
  updateStatus();
}

start();
