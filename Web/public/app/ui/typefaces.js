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
];

/** The face to use before anybody has chosen one. */
export const INITIAL_TYPEFACE = 'sans';

export const isTypeface = (id) => TYPEFACES.some((face) => face.id === id);

/** The face for `id`, or the system face for anything unknown. */
export function typefaceByID(id) {
  return TYPEFACES.find((face) => face.id === id) ?? TYPEFACES[0];
}

/**
 * Which faces to offer.
 *
 * The bundled ones always; the system ones only where they resolve. This is
 * the web's version of the Mac's `NSFont(name:) != nil` check, and it exists
 * for the same reason: a picker offering a face that is not there means
 * choosing it silently draws something else, which looks like the app
 * ignoring you.
 */
export function availableTypefaces() {
  return TYPEFACES.filter((face) => {
    if (face.id === 'sans' || face.bundled) return true;
    if (typeof document === 'undefined' || !document.fonts?.check) return false;
    try {
      return document.fonts.check(`16px "${face.family}"`);
    } catch {
      return false;
    }
  });
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
