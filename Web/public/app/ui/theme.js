// Theme selection and the Customize Theme popover.
//
// Mirrors PRD section 12: eight kirupa.com colors on a Light/Dark axis, held
// as two attributes on <html> so themes.css does all the work. The popover
// keeps draft state and only commits on Apply (T-6, T-7, T-8).

const COLOR_KEY = 'editorThemeColor';
const MODE_KEY = 'editorAppearanceMode';

export const THEME_COLORS = [
  { id: 'blue', title: 'Blue' },
  { id: 'yellow', title: 'Yellow' },
  { id: 'pink', title: 'Pink' },
  { id: 'green', title: 'Green' },
  { id: 'purple', title: 'Purple' },
  { id: 'pico8', title: 'Pico-8' },
  { id: 'black', title: 'Black' },
  { id: 'brown', title: 'Brown' },
];

export const APPEARANCE_MODES = [
  { id: 'light', title: 'Light' },
  { id: 'dark', title: 'Dark' },
];

const isColor = (value) => THEME_COLORS.some((color) => color.id === value);
const isMode = (value) => APPEARANCE_MODES.some((mode) => mode.id === value);

function read(key, fallback, valid) {
  try {
    const stored = localStorage.getItem(key);
    return valid(stored) ? stored : fallback;
  } catch {
    return fallback;
  }
}

function persist(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Private browsing can refuse writes; the theme still applies for the visit.
  }
}

/** T-5: the color defaults to Blue and the mode follows the OS on first run. */
export const theme = {
  color: read(COLOR_KEY, 'blue', isColor),
  mode: read(
    MODE_KEY,
    window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
    isMode
  ),

  apply() {
    document.documentElement.dataset.themeColor = this.color;
    document.documentElement.dataset.appearance = this.mode;
  },

  set(color, mode) {
    if (isColor(color)) {
      this.color = color;
      persist(COLOR_KEY, color);
    }
    if (isMode(mode)) {
      this.mode = mode;
      persist(MODE_KEY, mode);
    }
    this.apply();
  },
};

function swatchButton(color, isActive, onSelect) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'me-swatch';
  button.title = color.title;
  button.setAttribute('aria-label', color.title);
  button.setAttribute('aria-pressed', String(isActive));
  button.style.setProperty('--swatch-fill', `var(--me-swatch-${color.id})`);
  button.style.setProperty('--swatch-border', `var(--me-swatch-${color.id}-border)`);
  button.addEventListener('click', () => onSelect(color.id));
  return button;
}

const MODE_ICONS = {
  light: '<circle cx="8" cy="8" r="3.2"/><path d="M8 1v1.6M8 13.4V15M1 8h1.6M13.4 8H15M3 3l1.2 1.2M11.8 11.8L13 13M13 3l-1.2 1.2M4.2 11.8L3 13"/>',
  dark: '<path d="M13 9.5A5.6 5.6 0 0 1 6.5 3a5.6 5.6 0 1 0 6.5 6.5z"/>',
};

function modeButton(mode, isActive, onSelect) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'me-radio';
  button.setAttribute('aria-pressed', String(isActive));
  button.innerHTML = `<svg viewBox="0 0 16 16" aria-hidden="true">${MODE_ICONS[mode.id]}</svg>`;
  button.append(document.createTextNode(mode.title));
  button.addEventListener('click', () => onSelect(mode.id));
  return button;
}

/**
 * Opens the Customize Theme popover anchored under `anchor`.
 *
 * Draft selections only repaint the popover's own preview; the app is not
 * touched until Apply (T-7).
 */
export function openThemePopover(anchor, onApplied = () => {}) {
  const layer = document.getElementById('popoverLayer');
  layer.replaceChildren();

  let draftColor = theme.color;
  let draftMode = theme.mode;

  const popover = document.createElement('div');
  popover.className = 'me-popover';
  popover.setAttribute('role', 'dialog');
  popover.setAttribute('aria-label', 'Customize Theme');

  const title = document.createElement('p');
  title.className = 'me-popover__title';
  title.textContent = 'Customize Theme';

  const colorSection = document.createElement('div');
  colorSection.className = 'me-popover__section';
  const colorLabel = document.createElement('p');
  colorLabel.className = 'me-popover__label';
  colorLabel.textContent = 'Color';
  const swatches = document.createElement('div');
  swatches.className = 'me-swatches';
  colorSection.append(colorLabel, swatches);

  const modeSection = document.createElement('div');
  modeSection.className = 'me-popover__section';
  const modeLabel = document.createElement('p');
  modeLabel.className = 'me-popover__label';
  modeLabel.textContent = 'Background';
  const modes = document.createElement('div');
  modes.className = 'me-radio-row';
  modeSection.append(modeLabel, modes);

  const previewSection = document.createElement('div');
  previewSection.className = 'me-popover__section';
  const preview = document.createElement('div');
  preview.className = 'me-preview';
  preview.innerHTML =
    '<div class="me-preview__title">Preview</div>' +
    '<div class="me-preview__body">The quick brown fox jumps over the lazy dog.</div>' +
    '<span class="me-preview__accent">Selected text</span>';
  previewSection.append(preview);

  const buttons = document.createElement('div');
  buttons.className = 'me-popover__buttons';

  const close = () => {
    layer.replaceChildren();
    document.removeEventListener('keydown', onKeyDown, true);
    document.removeEventListener('pointerdown', onPointerDown, true);
  };

  function onKeyDown(event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      close(); // T-8: Escape discards the draft.
    }
  }

  function onPointerDown(event) {
    if (!popover.contains(event.target) && event.target !== anchor) close();
  }

  const cancel = document.createElement('button');
  cancel.type = 'button';
  cancel.className = 'me-button';
  cancel.textContent = 'Cancel';
  cancel.addEventListener('click', close);

  const apply = document.createElement('button');
  apply.type = 'button';
  apply.className = 'me-button me-button--default';
  apply.textContent = 'Apply';
  apply.addEventListener('click', () => {
    theme.set(draftColor, draftMode);
    close();
    onApplied();
  });

  buttons.append(cancel, apply);

  // The preview reads the draft theme's variables without the rest of the app
  // seeing them, by scoping a hidden probe element to the draft attributes.
  const probe = document.createElement('div');
  probe.style.display = 'none';
  popover.append(probe);

  function repaint() {
    swatches.replaceChildren(
      ...THEME_COLORS.map((color) =>
        swatchButton(color, color.id === draftColor, (id) => {
          draftColor = id;
          repaint();
        })
      )
    );
    modes.replaceChildren(
      ...APPEARANCE_MODES.map((mode) =>
        modeButton(mode, mode.id === draftMode, (id) => {
          draftMode = id;
          repaint();
        })
      )
    );

    probe.dataset.themeColor = draftColor;
    probe.dataset.appearance = draftMode;
    const draft = getComputedStyle(probe);
    preview.style.setProperty('--preview-page', draft.getPropertyValue('--me-page-background'));
    preview.style.setProperty('--preview-text', draft.getPropertyValue('--me-primary-text'));
    preview.style.setProperty('--preview-accent', draft.getPropertyValue('--me-selection-background'));
    preview.style.setProperty('--preview-accent-text', draft.getPropertyValue('--me-selection-text'));
  }

  popover.append(title, colorSection, modeSection, previewSection, buttons);
  layer.append(popover);
  repaint();

  const rect = anchor.getBoundingClientRect();
  const width = popover.offsetWidth;
  popover.style.top = `${rect.bottom + 6}px`;
  popover.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))}px`;

  document.addEventListener('keydown', onKeyDown, true);
  document.addEventListener('pointerdown', onPointerDown, true);
}
