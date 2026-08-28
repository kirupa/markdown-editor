// Selecting an image, and resizing it by dragging a corner.
//
// The rendered view shows an image as a single atomic character, so there is
// no caret position "inside" it to hang a control off. Clicking one instead
// selects the whole reference, draws a frame with four corner handles over it,
// and opens a small panel underneath. Both edit the document text through the
// same pure functions as every other command — neither has state of its own
// beyond which image is selected and, mid-drag, the size being asked for.
//
// The frame and the panel are siblings of the surface rather than children of
// the image, because everything inside `.me-image` must contribute exactly zero
// characters to the document text (see `buildImage` in renderer.js). Anything
// nested in there would shift every offset after it.
//
// Dragging does not rewrite the document on every pointer move. It resizes the
// `img` element in place and commits once, on release, so a resize is a single
// undoable edit rather than one per pixel of travel.

import { proportionalSize } from '../core/image-tag.js';

const MIN_SIZE = 1;
const MAX_SIZE = 10000;
/** Small enough to be a deliberate choice, large enough to still grab. */
const MIN_DRAG_SIZE = 24;
/** How far one arrow key press moves a handle, and with Shift held. */
const KEY_STEP = 10;
const KEY_STEP_FINE = 1;

// `grows` is the direction along x that makes the image bigger, so one
// expression covers all four corners.
const CORNERS = [
  { id: 'nw', grows: -1, label: 'Resize from the top left' },
  { id: 'ne', grows: 1, label: 'Resize from the top right' },
  { id: 'sw', grows: -1, label: 'Resize from the bottom left' },
  { id: 'se', grows: 1, label: 'Resize from the bottom right' },
];

export class ImageSelection {
  /**
   * @param {HTMLElement} host - The element the frame and panel are positioned within.
   * @param {(range: {location:number,length:number}, size:{width:number|null,height:number|null}) => void} onResize
   */
  constructor(host, onResize) {
    this._host = host;
    this._onResize = onResize;
    this._image = null;
    this._drag = null;
    this._frame = this._buildFrame();
    this._panel = this._buildPanel();
    this._host.append(this._frame, this._panel);
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
      this._frame.hidden = true;
      return false;
    }
    this._image.classList.add('me-image--selected');
    this._fillFields();
    this._panel.hidden = false;
    this._frame.hidden = false;
    this._position();
    return true;
  }

  /** Whether `node` is inside the currently selected image. */
  contains(node) {
    return this._image !== null && this._image.contains(node);
  }

  /** Whether `node` is one of the controls, whose clicks must not clear it. */
  ownsControl(node) {
    return this._panel.contains(node) || this._frame.contains(node);
  }

  clear() {
    this.select(null);
  }

  /**
   * Re-anchor to the equivalent image after a re-render, which replaces every
   * element. Without this the controls would vanish on the first keystroke.
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

  /** Keep the controls over the image when the pane scrolls or is resized. */
  reposition() {
    if (this._image && !this._frame.hidden) this._position();
  }

  // ── Private ──────────────────────────────────────────────────────────────

  _buildFrame() {
    const frame = document.createElement('div');
    frame.className = 'me-image-frame';
    frame.hidden = true;
    frame.contentEditable = 'false';

    for (const corner of CORNERS) {
      const handle = document.createElement('button');
      handle.type = 'button';
      handle.className =
        `me-image-frame__handle me-image-frame__handle--${corner.id}`;
      handle.setAttribute('aria-label', corner.label);
      handle.addEventListener('pointerdown', (event) =>
        this._beginDrag(event, corner)
      );
      handle.addEventListener('keydown', (event) =>
        this._handleKey(event, corner)
      );
      frame.append(handle);
    }
    return frame;
  }

  /**
   * Arrow keys resize by a step, so a handle is not the one control in the
   * editor that needs a pointer. Shift narrows the step to a single pixel.
   */
  _handleKey(event, corner) {
    const along = { ArrowRight: 1, ArrowLeft: -1, ArrowUp: -1, ArrowDown: 1 };
    if (!(event.key in along)) return;
    const img = this._image?.querySelector('img');
    const natural = img ? naturalSize(img) : null;
    if (!natural) return;

    event.preventDefault();
    const step = event.shiftKey ? KEY_STEP_FINE : KEY_STEP;
    // Vertical keys read naturally on their own axis: Up shrinks, Down grows,
    // whichever corner is held. Horizontal keys follow the corner.
    const direction = event.key.startsWith('ArrowUp') ||
      event.key.startsWith('ArrowDown')
      ? along[event.key]
      : along[event.key] * corner.grows;

    const size = this._proportional(
      img.getBoundingClientRect().width + step * direction,
      natural
    );
    if (!size) return;
    this._show(img, size);
    this._commit(size);
  }

  _beginDrag(event, corner) {
    if (event.button !== 0 || !this._image) return;
    const img = this._image.querySelector('img');
    const natural = img ? naturalSize(img) : null;
    if (!natural) return;

    // Keep the surface from taking focus and clearing the very selection this
    // drag is about to edit.
    event.preventDefault();
    event.stopPropagation();
    const handle = event.currentTarget;
    handle.setPointerCapture(event.pointerId);
    handle.focus({ preventScroll: true });

    this._drag = {
      corner,
      pointerId: event.pointerId,
      startX: event.clientX,
      startWidth: img.getBoundingClientRect().width,
      natural,
      size: null,
    };
    this._frame.dataset.dragging = 'true';

    const move = (moveEvent) => this._continueDrag(moveEvent);
    const end = (endEvent) => {
      handle.removeEventListener('pointermove', move);
      handle.removeEventListener('pointerup', end);
      handle.removeEventListener('pointercancel', end);
      this._endDrag(endEvent);
    };
    handle.addEventListener('pointermove', move);
    handle.addEventListener('pointerup', end);
    handle.addEventListener('pointercancel', end);
  }

  _continueDrag(event) {
    const drag = this._drag;
    if (!drag || event.pointerId !== drag.pointerId) return;
    const img = this._image?.querySelector('img');
    if (!img) return;

    const travel = (event.clientX - drag.startX) * drag.corner.grows;
    const size = this._proportional(drag.startWidth + travel, drag.natural);
    if (!size) return;

    drag.size = size;
    // Shown at once on the element. The document is still untouched: a drag is
    // one edit, applied when the pointer lifts.
    this._show(img, size);
  }

  _endDrag() {
    const drag = this._drag;
    this._drag = null;
    delete this._frame.dataset.dragging;
    if (!drag?.size || !this._image) return;
    this._commit(drag.size);
  }

  /**
   * The proportional size for a wanted width, clamped so the image can neither
   * disappear nor grow past what the surface can show. Overshooting the pane
   * would write a number the layout then ignores, and the handle would come
   * away from the corner it is holding.
   */
  _proportional(wantedWidth, natural) {
    const width = clampRange(
      Math.round(wantedWidth),
      MIN_DRAG_SIZE,
      Math.max(MIN_DRAG_SIZE, this._availableWidth())
    );
    const size = proportionalSize({ width, natural, edited: 'width' });
    return size.width === null ? null : size;
  }

  /** Put a size on the element and in the fields, without touching the document. */
  _show(img, size) {
    img.setAttribute('width', String(size.width));
    img.setAttribute('height', String(size.height));
    this._width.value = String(size.width);
    this._height.value = String(size.height);
    this._position();
  }

  /** How wide an image is allowed to get here, in CSS pixels. */
  _availableWidth() {
    const surface = this._host.querySelector('.me-surface') ?? this._host;
    const style = getComputedStyle(surface);
    const padding =
      Number.parseFloat(style.paddingLeft || '0') +
      Number.parseFloat(style.paddingRight || '0');
    return Math.round(surface.getBoundingClientRect().width - padding);
  }

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
    field.setAttribute('aria-label', title);
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

    this._commit(size);
  }

  _commit(size) {
    this._onResize(
      {
        location: Number(this._image.dataset.sourceLocation),
        length: Number(this._image.dataset.sourceLength),
      },
      size
    );
  }

  _position() {
    // Measure the image, not the wrapper: a wrapper also holds the broken-image
    // label, so its box is not the box the handles must sit on.
    const img = this._image.querySelector('img') ?? this._image;
    const image = img.getBoundingClientRect();
    const host = this._host.getBoundingClientRect();
    const left = image.left - host.left + this._host.scrollLeft;
    const top = image.top - host.top + this._host.scrollTop;

    this._frame.style.left = `${left}px`;
    this._frame.style.top = `${top}px`;
    this._frame.style.width = `${image.width}px`;
    this._frame.style.height = `${image.height}px`;

    this._panel.style.left = `${left}px`;
    this._panel.style.top = `${top + image.height + 8}px`;
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

function clampRange(value, low, high) {
  return Math.min(high, Math.max(low, value));
}

function labelled(text, field) {
  const label = document.createElement('label');
  label.className = 'me-image-size__label';
  const caption = document.createElement('span');
  caption.textContent = text;
  label.append(caption, field);
  return label;
}
