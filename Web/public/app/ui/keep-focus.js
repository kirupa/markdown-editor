// Why toolbar buttons cancel exactly one event, and which ones they must not.
//
// A formatting command acts on the live selection, so a button that takes
// focus would act on nothing. On iOS, moving focus also dismisses the
// keyboard, which shifts the whole layout on every tap.
//
// Cancelling `mousedown` is the entire fix, and it covers touch too: a tap
// synthesizes `mousedown` before `click`, and cancelling it suppresses the
// focus change without suppressing the click.
//
// Do NOT also cancel `touchstart` or `pointerdown`. Cancelling either one
// suppresses the whole compatibility chain, so `click` never fires and the
// control is simply dead on a phone — no popovers, no formatting, nothing.
// It also swallows the drag that scrolls the formatting palette sideways,
// since most of that row's width is buttons. This module exists so that rule
// has one home and one test, instead of being re-derived at each button.
//
// Losing focus anyway is survivable by design: `handleSelectionChange` ignores
// events while the surface is blurred, so `model.selection` still holds the
// range, `currentSelection()` falls back to it, and `applyResult` re-focuses
// and re-applies it.

/** Register the one listener that keeps focus in the editor. */
export function keepFocus(control) {
  control.addEventListener('mousedown', (event) => event.preventDefault());
  return control;
}
