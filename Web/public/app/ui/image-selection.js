// Selecting an image to change its size.
//
// The rendered view shows an image as a single atomic character, so there is
// no caret position "inside" it to hang a control off. Clicking one instead
// selects the whole reference and opens a small panel over it. The panel edits
// the document text through the same pure functions as every other command —
// it has no state of its own beyond which image is selected.

import { proportionalSize } from '../core/image-tag.js';

const MIN_SIZE = 1;
const MAX_SIZE = 10000;

export class ImageSelection {
  /**
   * @param {HTMLElement} host - The element the panel is positioned within.
   * @param {(range: {location:number,length:number}, size:{width:number|null,height:number|null}) => void} onResize
   */
  constructor(host, onResize) {
    this._host = host;
    this._onResize = onResize;
    this._image = null;
    this._panel = this._buildPanel();
    this._host.append(this._panel);
  }

  /**
   * Select the image element `wrapper` (a `.me-image`), or pass null to clear.
   * Returns true when something was selected.
   */
  select(wrapper) {
    if (this._image) this._image.classList.remove('me-image--selected');
    this._image = wrapper ?? null;
    if (!this._image) {
      this._panel.hidden = true;
      return false;
    }
    this._image.classList.add('me-image--selected');
    this._fillFields();
    this._panel.hidden = false;
    this._position();
    return true;
  }

  /** Whether `node` is inside the currently selected image. */
  contains(node) {
    return this._image !== null && this._image.contains(node);
  }

  /** Whether `node` is inside the panel itself, whose clicks must not clear it. */
  ownsControl(node) {
    return this._panel.contains(node);
  }

  clear() {
    this.select(null);
  }

  /**
   * Re-anchor to the equivalent image after a re-render, which replaces every
   * element. Without this the panel would vanish on its own first keystroke.
   */
  restore() {
    if (!this._image) return;
    const location = this._image.dataset.sourceLocation;
    const replacement = this._host.querySelector(
      `.me-image[data-source-location="${CSS.escape(location)}"]`
    );
    this._image = null;
    this.select(replacement);
  }

  // ── Private ──────────────────────────────────────────────────────────────

  _buildPanel() {
    const panel = document.createElement('div');
    panel.className = 'me-image-size';
    panel.hidden = true;
    panel.contentEditable = 'false';

    this._width = this._buildField('Width', 'width');
    this._height = this._buildField('Height', 'height');

    const reset = document.createElement('button');
    reset.type = 'button';
    reset.className = 'me-image-size__reset';
    reset.textContent = 'Reset';
    reset.title = 'Use the image’s own size';
    reset.addEventListener('click', () => this._apply(null, 'width'));

    panel.append(
      labelled('W', this._width),
      labelled('H', this._height),
      reset
    );
    // Keep the click from reaching the surface, which would clear the
    // selection the panel is editing.
    panel.addEventListener('mousedown', (event) => event.preventDefault());
    return panel;
  }

  _buildField(title, edited) {
    const field = document.createElement('input');
    field.type = 'number';
    field.min = String(MIN_SIZE);
    field.max = String(MAX_SIZE);
    field.className = 'me-image-size__field';
    field.title = title;
    field.addEventListener('input', () => {
      const typed = field.value.trim();
      if (typed === '') return;   // mid-edit; wait for a number
      this._apply(Number(typed), edited);
    });
    return field;
  }

  /** Read the size the document currently gives this image. */
  _fillFields() {
    const img = this._image.querySelector('img');
    this._width.value = img?.getAttribute('width') ?? '';
    this._height.value = img?.getAttribute('height') ?? '';
  }

  _apply(value, edited) {
    const img = this._image?.querySelector('img');
    if (!img) return;

    const size = proportionalSize({
      [edited]: clampSize(value),
      natural: naturalSize(img),
      edited,
    });

    // Show the derived side immediately. The document is the source of truth,
    // but a re-render is asynchronous and the field must not lag behind the
    // number being typed into it.
    if (edited === 'width') this._height.value = size.height ?? '';
    else this._width.value = size.width ?? '';

    this._onResize(
      {
        location: Number(this._image.dataset.sourceLocation),
        length: Number(this._image.dataset.sourceLength),
      },
      size
    );
  }

  _position() {
    const image = this._image.getBoundingClientRect();
    const host = this._host.getBoundingClientRect();
    this._panel.style.left = `${image.left - host.left + this._host.scrollLeft}px`;
    this._panel.style.top =
      `${image.bottom - host.top + this._host.scrollTop + 6}px`;
  }
}

/** The image's own pixel dimensions, or null while it is still loading. */
function naturalSize(img) {
  if (!img.naturalWidth || !img.naturalHeight) return null;
  return { width: img.naturalWidth, height: img.naturalHeight };
}

function clampSize(value) {
  if (value === null || !Number.isFinite(value)) return null;
  const whole = Math.round(value);
  if (whole < MIN_SIZE) return null;
  return Math.min(whole, MAX_SIZE);
}

function labelled(text, field) {
  const label = document.createElement('label');
  label.className = 'me-image-size__label';
  const caption = document.createElement('span');
  caption.textContent = text;
  label.append(caption, field);
  return label;
}
