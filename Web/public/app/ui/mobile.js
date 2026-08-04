// Mobile layout (PRD WB-1 … WB-14).
//
// The desktop chrome assumes a pointer and a wide window: a menu bar whose
// items are hover targets, a single-row toolbar of ~20 small buttons, a
// permanently docked sidebar, and a status bar. On a phone that is most of the
// screen and none of it is comfortably tappable.
//
// So this is a different arrangement of the *same* commands, not a different
// editor. Every control here calls the identical command table the menus and
// desktop toolbar use, which is why formatting, undo, and theming behave the
// same in both layouts without a second implementation to keep in step.
//
// Three pieces:
//   - a slim top bar: files drawer, document name, Undo, theme, "save for
//     later" checkbox;
//   - a floating formatting bar near the thumb, scrolled horizontally;
//   - an overflow sheet for the things that no longer have a menu.

import { ICONS } from './toolbar.js';

/** Icons that only the mobile layout needs. */
const MOBILE_ICONS = {
  files:
    '<path d="M2.4 4.2h3.6l1.2 1.4h6.4v7.2a1.4 1.4 0 0 1-1.4 1.4H3.8a1.4 1.4 0 0 1-1.4-1.4z"/><path d="M2.4 4.2V3.2a1 1 0 0 1 1-1h2.2l1.2 1.4"/>',
  undo: '<path d="M3.2 7.8h6.4a3.4 3.4 0 0 1 0 6.8H6.2"/><path d="M6 4.6 2.8 7.8 6 11"/>',
  bookmark: '<path d="M4.2 2.6h7.6v11L8 10.9l-3.8 2.7z"/>',
  more: '<circle cx="3.4" cy="8" r="1.2" class="me-fill"/><circle cx="8" cy="8" r="1.2" class="me-fill"/><circle cx="12.6" cy="8" r="1.2" class="me-fill"/>',
  desktop:
    '<rect x="1.8" y="3" width="12.4" height="8.4" rx="1.4"/><path d="M5.6 13.6h4.8"/>',
  newDocument:
    '<path d="M3.6 1.9h5.2L12.4 5.5v8.6H3.6z"/><path d="M8.7 2v3.6h3.6"/><path d="M8 8v3.6M6.2 9.8h3.6"/>',
  save: '<path d="M3.4 2.6h7l2.6 2.6v8.2H3.4z"/><path d="M5.6 2.6v3.6h4.6V2.6M5.6 13.4v-3.8h4.8v3.8"/>',
  paragraph: '<path d="M3 3.2h10M3 6.6h10M3 10h7M3 13.4h10"/>',
};

const ALL_ICONS = { ...ICONS, ...MOBILE_ICONS };

function svg(name) {
  return `<svg viewBox="0 0 16 16" aria-hidden="true">${ALL_ICONS[name]}</svg>`;
}

/**
 * Buttons must not steal focus: a formatting command acts on the live
 * selection, and on iOS taking focus also dismisses the keyboard, which would
 * make the bar jump down the screen on every tap.
 */
function keepFocus(button) {
  button.addEventListener('mousedown', (event) => event.preventDefault());
  button.addEventListener('touchstart', (event) => event.preventDefault(), { passive: false });
  return button;
}

function button(className, iconName, title, onClick) {
  const element = document.createElement('button');
  element.type = 'button';
  element.className = className;
  element.title = title;
  element.setAttribute('aria-label', title);
  element.innerHTML = svg(iconName);
  element.addEventListener('click', onClick);
  return keepFocus(element);
}

/**
 * A bottom sheet for commands that lost their menu. Rendered into the shared
 * popover layer so it stacks and dismisses like every other transient surface.
 */
function openSheet(items) {
  const layer = document.getElementById('popoverLayer');
  layer.replaceChildren();

  const backdrop = document.createElement('div');
  backdrop.className = 'me-sheet-backdrop';

  const sheet = document.createElement('div');
  sheet.className = 'me-sheet';
  sheet.setAttribute('role', 'dialog');
  sheet.setAttribute('aria-label', 'More');

  function close() {
    layer.replaceChildren();
    document.removeEventListener('keydown', onKeyDown, true);
  }

  function onKeyDown(event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      close();
    }
  }

  for (const item of items) {
    if (item.separator) {
      const rule = document.createElement('div');
      rule.className = 'me-sheet__separator';
      sheet.append(rule);
      continue;
    }

    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'me-sheet__item';
    if (item.selected) row.setAttribute('aria-current', 'true');
    row.disabled = item.enabled === false;
    row.innerHTML = `${item.icon ? svg(item.icon) : '<span class="me-sheet__gap"></span>'}<span>${item.label}</span>`;
    row.addEventListener('click', () => {
      close();
      item.action?.();
    });
    sheet.append(row);
  }

  backdrop.addEventListener('click', close);
  layer.append(backdrop, sheet);
  document.addEventListener('keydown', onKeyDown, true);
  return close;
}

/**
 * Keeps the floating bar above the on-screen keyboard.
 *
 * A phone keyboard shrinks the *visual* viewport but leaves the layout
 * viewport alone, so `position: fixed; bottom: 0` ends up underneath it. The
 * difference between the two viewports is exactly how far up the bar has to
 * move, published as a CSS variable so the stylesheet owns the arithmetic.
 */
function trackKeyboard(root) {
  const viewport = window.visualViewport;
  if (!viewport) return () => {};

  const update = () => {
    const overlap = Math.max(
      0,
      window.innerHeight - viewport.height - viewport.offsetTop
    );
    root.style.setProperty('--me-keyboard-inset', `${Math.round(overlap)}px`);
  };

  viewport.addEventListener('resize', update);
  viewport.addEventListener('scroll', update);
  update();

  return () => {
    viewport.removeEventListener('resize', update);
    viewport.removeEventListener('scroll', update);
    root.style.removeProperty('--me-keyboard-inset');
  };
}

/**
 * Publishes the floating bar's height so the editor can pad beneath it.
 *
 * The bar is absolutely positioned, so it covers the bottom of the document
 * rather than displacing it: at full scroll the last lines sit behind it and
 * no further scrolling can reveal them. Measuring is better than a constant
 * because the height follows the heading `<select>` and the user's text size.
 */
function trackBarHeight(root, formatBar) {
  const update = () => {
    const height = formatBar.hidden ? 0 : formatBar.offsetHeight;
    root.style.setProperty('--me-format-height', `${Math.round(height)}px`);
  };

  if (typeof ResizeObserver === 'undefined') {
    update();
    return () => root.style.removeProperty('--me-format-height');
  }

  const observer = new ResizeObserver(update);
  observer.observe(formatBar);
  update();

  return () => {
    observer.disconnect();
    root.style.removeProperty('--me-format-height');
  };
}

/**
 * Pins the viewport while the mobile layout is on.
 *
 * The app already fills the screen and every scroll happens inside a pane, so
 * pinching or dragging the page itself does nothing useful — it just slides
 * the fixed top bar and floating tools out of reach.
 *
 * This takes three separate mechanisms because no one of them is enough. The
 * meta tag covers Android. `touch-action` in the stylesheet drops pinch and
 * double-tap zoom. iOS Safari has ignored `user-scalable=no` since iOS 10 and
 * never routes pinch through touch events, so its own gesture events have to
 * be cancelled, and a two-finger drag with them.
 *
 * Releasing restores the original meta tag, so a phone deliberately left in
 * Desktop Layout keeps pinch zoom — the cramped desktop chrome needs it.
 */
function lockViewport() {
  const meta = document.querySelector('meta[name="viewport"]');
  const original = meta ? meta.getAttribute('content') : null;
  if (meta && original !== null && !original.includes('user-scalable')) {
    meta.setAttribute('content', `${original}, maximum-scale=1, user-scalable=no`);
  }

  // The stylesheet keys off this rather than off `.me-app`, because a touch
  // action is the intersection of the element's and every ancestor's, so it
  // has to be set above the popover layer to cover sheets too.
  document.documentElement.dataset.meViewport = 'locked';

  const blockGesture = (event) => event.preventDefault();
  const blockPinch = (event) => {
    if (event.touches.length > 1) event.preventDefault();
  };

  document.addEventListener('gesturestart', blockGesture, { passive: false });
  document.addEventListener('gesturechange', blockGesture, { passive: false });
  document.addEventListener('gestureend', blockGesture, { passive: false });
  document.addEventListener('touchmove', blockPinch, { passive: false });

  return () => {
    if (meta && original !== null) meta.setAttribute('content', original);
    delete document.documentElement.dataset.meViewport;
    document.removeEventListener('gesturestart', blockGesture);
    document.removeEventListener('gesturechange', blockGesture);
    document.removeEventListener('gestureend', blockGesture);
    document.removeEventListener('touchmove', blockPinch);
  };
}

/**
 * @param {object} options
 * @param {HTMLElement} options.root         the `.me-app` element
 * @param {HTMLElement} options.topBar       container for the top bar
 * @param {HTMLElement} options.formatBar    container for the floating bar
 * @param {object} options.commands          the shared command table
 * @param {object} options.state             read-only accessors into app state
 */
export function buildMobileUI({ root, topBar, formatBar, commands, state }) {
  let releaseKeyboardTracking = null;
  let releaseBarTracking = null;
  let releaseViewportLock = null;

  // ---- top bar ------------------------------------------------------------

  const filesButton = button('me-mobile__button', 'files', 'Files', () =>
    commands.toggleSidebar()
  );

  const title = document.createElement('button');
  title.type = 'button';
  title.className = 'me-mobile__title';
  title.addEventListener('click', () => commands.showWelcome());

  const undoButton = button('me-mobile__button', 'undo', 'Undo', () => commands.undo());

  const themeButton = button('me-mobile__button', 'theme', 'Theme', (event) =>
    commands.customizeTheme(event.currentTarget)
  );

  // A real checkbox, not a toggle button: it is a state the user sets, it has
  // to be reachable by assistive technology, and the label has to say what
  // "later" means.
  const savedLabel = document.createElement('label');
  savedLabel.className = 'me-mobile__save';
  savedLabel.title = 'Save this file for later';
  const savedInput = document.createElement('input');
  savedInput.type = 'checkbox';
  savedInput.id = 'mobileSaveForLater';
  const savedText = document.createElement('span');
  savedText.className = 'me-mobile__save-box';
  savedText.innerHTML = svg('bookmark');
  const savedName = document.createElement('span');
  savedName.className = 'me-visually-hidden';
  savedName.textContent = 'Save this file for later';
  savedLabel.append(savedInput, savedText, savedName);
  savedInput.addEventListener('change', () => {
    commands.setSavedForLater(savedInput.checked);
  });

  const moreButton = button('me-mobile__button', 'more', 'More', () => {
    const mode = state.mode();
    openSheet([
      {
        label: 'Rich Text',
        icon: 'paragraph',
        selected: mode === 'rich',
        action: () => commands.setMode('rich'),
      },
      {
        label: 'Markdown',
        icon: 'code',
        selected: mode === 'source',
        action: () => commands.setMode('source'),
      },
      { separator: true },
      { label: 'New Document', icon: 'newDocument', action: () => commands.newDocument() },
      { label: 'Save', icon: 'save', action: () => commands.save() },
      { separator: true },
      { label: 'Desktop Layout', icon: 'desktop', action: () => commands.setMobileLayout(false) },
    ]);
  });

  topBar.replaceChildren(
    filesButton,
    title,
    undoButton,
    themeButton,
    savedLabel,
    moreButton
  );

  // ---- floating formatting bar -------------------------------------------

  const headings = document.createElement('select');
  headings.className = 'me-format__select';
  headings.setAttribute('aria-label', 'Paragraph Style');
  for (const [value, label] of [
    ['0', 'Body'],
    ['1', 'H1'],
    ['2', 'H2'],
    ['3', 'H3'],
    ['4', 'H4'],
    ['5', 'H5'],
    ['6', 'H6'],
  ]) {
    headings.append(new Option(label, value));
  }
  headings.addEventListener('change', () => commands.heading(Number(headings.value)));

  const formatButton = (icon, label, action) => button('me-format__button', icon, label, action);

  const inlineButtons = new Map([
    ['bold', formatButton('bold', 'Bold', () => commands.inline('bold'))],
    ['italic', formatButton('italic', 'Italic', () => commands.inline('italic'))],
    ['underline', formatButton('underline', 'Underline', () => commands.inline('underline'))],
    [
      'strikethrough',
      formatButton('strikethrough', 'Strikethrough', () => commands.inline('strikethrough')),
    ],
    ['inlineCode', formatButton('code', 'Inline Code', () => commands.inline('inlineCode'))],
  ]);

  const listButtons = new Map([
    ['bulleted', formatButton('bulletedList', 'Bulleted List', () => commands.list('bulleted'))],
    ['numbered', formatButton('numberedList', 'Numbered List', () => commands.list('numbered'))],
    ['task', formatButton('taskList', 'Task List', () => commands.list('task'))],
  ]);

  const quoteButton = formatButton('quote', 'Block Quote', () => commands.quote());
  const codeBlockButton = formatButton('codeBlock', 'Code Block', () => commands.codeBlock());

  const divider = () => {
    const element = document.createElement('span');
    element.className = 'me-format__divider';
    return element;
  };

  const scroller = document.createElement('div');
  scroller.className = 'me-format__scroller';
  scroller.append(
    headings,
    divider(),
    ...inlineButtons.values(),
    divider(),
    ...listButtons.values(),
    divider(),
    quoteButton,
    codeBlockButton,
    divider(),
    formatButton('link', 'Insert Link', () => commands.link()),
    formatButton('image', 'Add Image', () => commands.image()),
    formatButton('rule', 'Horizontal Rule', () => commands.horizontalRule())
  );

  formatBar.replaceChildren(scroller);

  return {
    setEnabled(enabled) {
      topBar.hidden = !enabled;
      formatBar.hidden = !enabled;
      if (enabled) {
        releaseKeyboardTracking ??= trackKeyboard(root);
        // After unhiding, so the bar has a height to measure.
        releaseBarTracking ??= trackBarHeight(root, formatBar);
        releaseViewportLock ??= lockViewport();
      } else {
        releaseKeyboardTracking?.();
        releaseKeyboardTracking = null;
        releaseBarTracking?.();
        releaseBarTracking = null;
        releaseViewportLock?.();
        releaseViewportLock = null;
      }
    },

    /** Mirrors document identity, dirtiness, undo availability, and the flag. */
    refresh() {
      const name = state.documentName();
      title.textContent = state.isDirty() ? `${name} •` : name;
      title.title = state.documentPath() || name;
      undoButton.disabled = !state.canUndo();
      // An unsaved document has no path, so there is nothing to remember yet.
      savedInput.disabled = !state.documentPath();
      savedInput.checked = state.isSavedForLater();
      savedLabel.dataset.checked = String(savedInput.checked);
    },

    setActiveStyles({ inline = new Set(), list = null, quote = false, heading = 0 } = {}) {
      for (const [name, element] of inlineButtons) {
        element.setAttribute('aria-pressed', String(inline.has(name)));
      }
      for (const [name, element] of listButtons) {
        element.setAttribute('aria-pressed', String(list === name));
      }
      quoteButton.setAttribute('aria-pressed', String(quote));
      if (document.activeElement !== headings) headings.value = String(heading);
    },

    setMode() {
      // The mode lives in the overflow sheet, which is rebuilt on each open.
    },
  };
}
