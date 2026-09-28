// The faces text can be set in: the document's, through Customize Theme, and
// the critique's hand, through its menu in the rail.
//
// One catalog for both, as on the Mac (EditorTypeface.swift), so the two menus
// can never offer different lists. The ids are the Mac's raw values, so a
// choice means the same face on either platform.

/**
 * A choice rather than a decision, because this one is taste: a marker, a
 * drafting hand and a pen are three different tones of voice for the same
 * words, and which one reads right is not something to settle on somebody's
 * behalf.
 *
 * `scale` is what to multiply a requested size by so every face lands at the
 * same *read* size, measured from x-height rather than cap height -- these
 * faces disagree about capitals far more than about lowercase, and almost
 * every word is lowercase. The numbers are the macOS build's, measured from the
 * same font files.
 */
export const TYPEFACES = [
  { id: 'sans', title: 'System Sans', family: '', scale: 1.0, bundled: false },
  { id: 'architectsDaughter', title: 'Architects Daughter', family: 'Architects Daughter', scale: 1.19, bundled: true },
  { id: 'caveat', title: 'Caveat', family: 'Caveat', scale: 1.28, bundled: true },
  { id: 'indieFlower', title: 'Indie Flower', family: 'Indie Flower', scale: 1.12, bundled: true },
  { id: 'patrickHand', title: 'Patrick Hand', family: 'Patrick Hand', scale: 1.09, bundled: true },
  { id: 'shadowsIntoLight', title: 'Shadows Into Light', family: 'Shadows Into Light', scale: 0.84, bundled: true },
  { id: 'gloriaHallelujah', title: 'Gloria Hallelujah', family: 'Gloria Hallelujah', scale: 0.90, bundled: true },
  { id: 'kalam', title: 'Kalam', family: 'Kalam', scale: 0.97, bundled: true },
  { id: 'permanentMarker', title: 'Permanent Marker', family: 'Permanent Marker', scale: 0.84, bundled: true },
  { id: 'bradleyHand', title: 'Bradley Hand', family: 'Bradley Hand', scale: 1.03, bundled: false },
  { id: 'markerFelt', title: 'Marker Felt', family: 'Marker Felt', scale: 0.88, bundled: false },
  { id: 'noteworthy', title: 'Noteworthy', family: 'Noteworthy', scale: 0.94, bundled: false },
  { id: 'chalkboard', title: 'Chalkboard', family: 'Chalkboard SE', scale: 1.01, bundled: false },
  // Offered only where somebody has installed them, and never shipped: their
  // licence is for personal use and forbids embedding them or passing them on,
  // so they cannot be served from here the way the bundled faces are.
  { id: 'qeDaveMergens', title: 'QE Dave Mergens', family: 'QEDaveMergens', scale: 1.36, bundled: false },
  { id: 'qeJulianDean', title: 'QE Julian Dean', family: 'QEJulianDean', scale: 1.57, bundled: false },
];

/** The face to use before anybody has chosen one. */
export const INITIAL_TYPEFACE = 'sans';

export const isTypeface = (id) => TYPEFACES.some((face) => face.id === id);

/** The face for `id`, or the system face for anything unknown. */
export function typefaceByID(id) {
  return TYPEFACES.find((face) => face.id === id) ?? TYPEFACES[0];
}

const PROBE_TEXT = 'mmmmmmmmmmlli1WQ@#';
const GENERIC_FAMILIES = ['monospace', 'serif', 'sans-serif'];
const drawable = new Map();

/**
 * Whether the browser will draw text in `family`, a face no stylesheet here
 * declares.
 *
 * Measured rather than asked. `document.fonts.check()` answers whether
 * anything still needs loading, and for a family nothing declares, nothing
 * ever does -- so WebKit and Chrome both say yes to a family that does not
 * exist. A face that is really there changes the width of the sample set in
 * front of at least one generic family; one that is not falls straight through
 * to the generic. A browser that hides installed faces from pages, as Safari
 * does, measures as not having them, which is the truth as far as drawing goes.
 */
export function isDrawableFamily(family) {
  if (drawable.has(family)) return drawable.get(family);
  let found = false;
  try {
    const context =
      typeof document === 'undefined' ? null : document.createElement('canvas').getContext('2d');
    found =
      context !== null &&
      GENERIC_FAMILIES.some((generic) => {
        context.font = `72px ${generic}`;
        const fallback = context.measureText(PROBE_TEXT).width;
        context.font = `72px "${family}", ${generic}`;
        return context.measureText(PROBE_TEXT).width !== fallback;
      });
  } catch {
    found = false;
  }
  drawable.set(family, found);
  return found;
}

/**
 * Which faces to offer.
 *
 * The bundled ones always; the rest only where they resolve. This is the web's
 * version of the Mac's `NSFont(name:) != nil` check, and it exists for the
 * same reason: a picker offering a face that is not there means choosing it
 * silently draws something else, which looks like the app ignoring you.
 */
export function availableTypefaces() {
  return TYPEFACES.filter(
    (face) => face.id === 'sans' || face.bundled || isDrawableFamily(face.family)
  );
}

/**
 * The face that will actually draw for `id`: a face this machine does not
 * have is the system face, and is said to be, rather than drawing the system
 * face at another face's scale.
 */
export function resolvedTypeface(id) {
  const face = typefaceByID(id);
  return availableTypefaces().includes(face) ? face : TYPEFACES[0];
}

/** A CSS `font-family` value for `face`, ending in `fallback`. */
export function typefaceFamily(face, fallback) {
  return face.family === '' ? fallback : `"${face.family}", ${fallback}`;
}

/**
 * A `<select>` of every face this machine can draw, grouped as the Mac's menus
 * are, with each name set in its own face -- a list of font names asks you to
 * guess and then look, and showing them is the whole answer to the question.
 */
export function typefaceSelect({ selected, className = '', onChange }) {
  const select = document.createElement('select');
  if (className) select.className = className;

  const faces = availableTypefaces();
  const add = (parent, face) => {
    const option = document.createElement('option');
    option.value = face.id;
    option.textContent = face.title;
    if (face.family !== '') option.style.fontFamily = `"${face.family}"`;
    if (face.id === selected) option.selected = true;
    parent.append(option);
  };
  const group = (label, members) => {
    if (members.length === 0) return;
    const optgroup = document.createElement('optgroup');
    optgroup.label = label;
    for (const face of members) add(optgroup, face);
    select.append(optgroup);
  };

  add(select, faces[0]);
  group('Bundled', faces.filter((face) => face.bundled));
  group('From your computer', faces.filter((face) => !face.bundled && face.id !== 'sans'));

  select.addEventListener('change', () => onChange(select.value));
  return select;
}
