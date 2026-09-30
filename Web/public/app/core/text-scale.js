// How large the document is drawn — Customize Theme ▸ Size (T-23).
//
// The same rule as EditorColorTheme.textScale on the Mac. Faces set at the
// same size are not the same size to the eye, so a hand that reads small can
// be brought up and one that shouts brought down. It scales everything the
// text is set with — type, the space between lines and paragraphs, and the
// indents of lists, quotes and code — while the column and the pictures in it
// stay the size they were. The stylesheet does the multiplying; this only
// decides which numbers are allowed.

export const TEXT_SCALE_KEY = 'editorTextScale';

/** Three quarters of the type scale to half as large again. */
export const TEXT_SCALE_MIN = 0.75;
export const TEXT_SCALE_MAX = 1.5;

/** A slider stop every 5%, so 100% is always one of them. */
export const TEXT_SCALE_STEP = 0.05;

/**
 * `value` brought into range and rounded to a whole percent, so a slider's
 * 1.0000000000000002 is the 100% it says it is. Anything that is not a number
 * — nothing stored yet, or something stored by hand — reads as 100%.
 */
export function clampedTextScale(value) {
  let number = Number.NaN;
  if (typeof value === 'number') number = value;
  else if (typeof value === 'string' && value.trim() !== '') number = Number(value);
  if (!Number.isFinite(number)) return 1;
  const clamped = Math.min(Math.max(number, TEXT_SCALE_MIN), TEXT_SCALE_MAX);
  return Math.round(clamped * 100) / 100;
}

/** The scale as the popover shows it: `125%`. */
export function textScalePercent(value) {
  return `${Math.round(clampedTextScale(value) * 100)}%`;
}
