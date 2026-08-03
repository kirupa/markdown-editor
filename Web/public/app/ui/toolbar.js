// Formatting toolbar (PRD F-1 … F-11, Y-*).
//
// Every control routes through the same command table the menus use, so a
// toolbar click and a keyboard shortcut are literally the same code path.
// Buttons report their state through `aria-pressed`, which is also what the
// stylesheet keys the active look off — one source of truth, no class juggling.

const ICONS = {
  bold: '<path d="M4.4 2.6h4a2.7 2.7 0 0 1 0 5.4h-4zM4.4 8h4.7a2.75 2.75 0 0 1 0 5.5H4.4z"/>',
  italic: '<path d="M6.6 2.9h5M4.6 13.1h5M9.5 2.9 6.7 13.1"/>',
  underline: '<path d="M4.4 2.7v5a3.6 3.6 0 0 0 7.2 0v-5M3.7 13.5h8.6"/>',
  strikethrough:
    '<path d="M11.5 4.3C10.9 3.1 9.7 2.5 8 2.5c-2 0-3.2 1-3.2 2.4 0 1.1.8 1.8 2.5 2.3M4.5 11.3c.6 1.4 1.9 2.2 3.7 2.2 2 0 3.4-1 3.4-2.5 0-.9-.4-1.5-1.1-2M2.5 8h11"/>',
  code: '<path d="M6 4.5 2.7 8 6 11.5M10 4.5 13.3 8 10 11.5"/>',
  codeBlock:
    '<rect x="2.1" y="3.1" width="11.8" height="9.8" rx="2"/><path d="M6.4 6.5 4.9 8l1.5 1.5M9.6 6.5 11.1 8 9.6 9.5"/>',
  bulletedList:
    '<circle cx="3.1" cy="4.4" r="1.1" class="me-fill"/><circle cx="3.1" cy="8" r="1.1" class="me-fill"/><circle cx="3.1" cy="11.6" r="1.1" class="me-fill"/><path d="M6.3 4.4h7.3M6.3 8h7.3M6.3 11.6h7.3"/>',
  numberedList:
    '<path d="M2.1 3.3h1v2.6M1.7 5.9h1.9M1.7 7.4h1.9v1.3H2.3v1.2h1.3M1.7 11.6h1.9v2.6H1.7"/><path d="M6.3 4.4h7.3M6.3 8h7.3M6.3 12.4h7.3"/>',
  taskList:
    '<rect x="1.7" y="2.7" width="4" height="4" rx="1"/><rect x="1.7" y="9.3" width="4" height="4" rx="1"/><path d="M2.6 4.7 3.4 5.5 4.9 4"/><path d="M7.6 4.7h6.7M7.6 11.3h6.7"/>',
  quote:
    '<path d="M3.1 4.3h3.3v3.3c0 2-1.1 3.3-2.9 3.9M9.2 4.3h3.3v3.3c0 2-1.1 3.3-2.9 3.9"/>',
  link: '<path d="M6.7 9.3a2.9 2.9 0 0 0 4 0l2-2a2.85 2.85 0 1 0-4-4l-1 1M9.3 6.7a2.9 2.9 0 0 0-4 0l-2 2a2.85 2.85 0 1 0 4 4l1-1"/>',
  image:
    '<rect x="1.9" y="3.1" width="12.2" height="9.8" rx="1.8"/><circle cx="5.6" cy="6.4" r="1.1" class="me-fill"/><path d="M2.5 11.6 6 8.5l2.4 2.1L10.6 8l3 3.3"/>',
  rule: '<path d="M2.2 8h11.6"/><path d="M3.5 4.4h9M3.5 11.6h9" opacity="0.4"/>',
  theme:
    '<circle cx="8" cy="8" r="5.5"/><path d="M8 2.5a5.5 5.5 0 0 1 0 11z" class="me-fill"/>',
};

function iconButton(name, title, onClick) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'me-tool';
  button.title = title;
  button.setAttribute('aria-label', title);
  button.innerHTML = `<svg viewBox="0 0 16 16" aria-hidden="true">${ICONS[name]}</svg>`;
  // Keeping focus in the editor is what lets a command act on the live selection.
  button.addEventListener('mousedown', (event) => event.preventDefault());
  button.addEventListener('click', onClick);
  return button;
}

function group(...children) {
  const element = document.createElement('div');
  element.className = 'me-toolbar__group';
  element.append(...children);
  return element;
}

function separator() {
  const element = document.createElement('div');
  element.className = 'me-toolbar__separator';
  return element;
}

/**
 * @param {HTMLElement} root
 * @param {object} commands the shared command table from `main.js`
 */
export function buildToolbar(root, commands) {
  const segmented = document.createElement('div');
  segmented.className = 'me-segmented';
  segmented.setAttribute('role', 'group');
  segmented.setAttribute('aria-label', 'Editor mode');
  const modeButtons = new Map();
  for (const [mode, label] of [
    ['rich', 'Rich Text'],
    ['split', 'Side by Side'],
    ['source', 'Markdown'],
  ]) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'me-segmented__option';
    button.textContent = label;
    button.setAttribute('aria-pressed', 'false');
    button.addEventListener('mousedown', (event) => event.preventDefault());
    button.addEventListener('click', () => commands.setMode(mode));
    modeButtons.set(mode, button);
    segmented.append(button);
  }

  const headings = document.createElement('select');
  headings.className = 'me-tool me-tool--wide';
  headings.title = 'Paragraph style';
  headings.setAttribute('aria-label', 'Paragraph style');
  for (const [value, label] of [
    ['0', 'Body'],
    ['1', 'Heading 1'],
    ['2', 'Heading 2'],
    ['3', 'Heading 3'],
    ['4', 'Heading 4'],
    ['5', 'Heading 5'],
    ['6', 'Heading 6'],
  ]) {
    headings.append(new Option(label, value));
  }
  headings.addEventListener('change', () => {
    commands.heading(Number(headings.value));
  });

  const inlineButtons = new Map([
    ['bold', iconButton('bold', 'Bold (⌘B)', () => commands.inline('bold'))],
    ['italic', iconButton('italic', 'Italic (⌘I)', () => commands.inline('italic'))],
    ['underline', iconButton('underline', 'Underline (⌘U)', () => commands.inline('underline'))],
    [
      'strikethrough',
      iconButton('strikethrough', 'Strikethrough (⌃⌘K)', () => commands.inline('strikethrough')),
    ],
    ['inlineCode', iconButton('code', 'Inline Code (⌘E)', () => commands.inline('inlineCode'))],
  ]);

  const listButtons = new Map([
    [
      'bulleted',
      iconButton('bulletedList', 'Bulleted List (⇧⌘7)', () => commands.list('bulleted')),
    ],
    [
      'numbered',
      iconButton('numberedList', 'Numbered List (⇧⌘8)', () => commands.list('numbered')),
    ],
    ['task', iconButton('taskList', 'Task List (⇧⌘9)', () => commands.list('task'))],
  ]);

  const quoteButton = iconButton('quote', 'Block Quote (⌃⌘Q)', () => commands.quote());
  const codeBlockButton = iconButton('codeBlock', 'Code Block (⇧⌘E)', () => commands.codeBlock());
  const themeButton = iconButton('theme', 'Customize Theme…', (event) =>
    commands.customizeTheme(event.currentTarget)
  );

  const spacer = document.createElement('div');
  spacer.className = 'me-toolbar__spacer';

  root.replaceChildren(
    group(segmented),
    separator(),
    group(headings),
    separator(),
    group(...inlineButtons.values()),
    separator(),
    group(codeBlockButton, quoteButton),
    separator(),
    group(...listButtons.values()),
    separator(),
    group(
      iconButton('link', 'Insert Link (⌘K)', () => commands.link()),
      iconButton('image', 'Add Image (⇧⌘I)', () => commands.image()),
      iconButton('rule', 'Horizontal Rule (⌃⌘H)', () => commands.horizontalRule())
    ),
    spacer,
    group(themeButton)
  );

  return {
    setMode(mode) {
      for (const [name, button] of modeButtons) {
        button.setAttribute('aria-pressed', String(name === mode));
      }
    },

    /** F-11: reflects what is actually active at the caret. */
    setActiveStyles({ inline = new Set(), list = null, quote = false, heading = 0 } = {}) {
      for (const [name, button] of inlineButtons) {
        button.setAttribute('aria-pressed', String(inline.has(name)));
      }
      for (const [name, button] of listButtons) {
        button.setAttribute('aria-pressed', String(list === name));
      }
      quoteButton.setAttribute('aria-pressed', String(quote));
      if (document.activeElement !== headings) headings.value = String(heading);
    },
  };
}
