// The rule that a phone depends on, kept honest.
//
// Toolbar buttons cancel `mousedown` so the editor keeps focus and the live
// selection. Cancelling `touchstart` or `pointerdown` as well looks like the
// same idea and is not: it suppresses the compatibility chain a tap generates,
// so `click` never fires. Every button in the mobile layout was dead that way
// once — header icons, popovers, formatting, image insert — and nothing threw,
// so nothing pointed at the cause.
//
// A DOM test cannot catch it: `dispatchEvent` produces untrusted events, which
// never synthesize mouse events, so a fake tap "works" either way. What can be
// checked is the registration itself, which is why it lives behind one helper.

import { suite, test, expect, expectEqual } from './harness.js';
import { keepFocus } from '../app/ui/keep-focus.js';

/** A stand-in for a control that records what got registered on it. */
function recordingControl() {
  const registered = [];
  return {
    registered,
    addEventListener(type, handler, options) {
      registered.push({ type, handler, options });
    },
    typesFor(type) {
      return registered.filter((entry) => entry.type === type);
    },
  };
}

suite('Keeping focus in the editor', () => {
  test('cancels mousedown, so a command still sees the live selection', () => {
    const control = recordingControl();
    keepFocus(control);

    const registrations = control.typesFor('mousedown');
    expectEqual(registrations.length, 1, 'exactly one mousedown listener');

    let prevented = false;
    registrations[0].handler({
      preventDefault() {
        prevented = true;
      },
    });
    expect(prevented, 'the mousedown listener cancels the event');
  });

  for (const type of ['touchstart', 'pointerdown']) {
    test(`never listens for ${type}, which would suppress the click a tap generates`, () => {
      const control = recordingControl();
      keepFocus(control);
      expectEqual(
        control.typesFor(type).length,
        0,
        `cancelling ${type} leaves the button dead on a touch device`
      );
    });
  }

  test('cancels nothing beyond mousedown', () => {
    const control = recordingControl();
    keepFocus(control);
    expectEqual(
      control.registered.map((entry) => entry.type).join(','),
      'mousedown',
      'one listener, and it is the harmless one'
    );
  });

  test('returns the control, so it can wrap a button expression', () => {
    const control = recordingControl();
    expect(keepFocus(control) === control, 'keepFocus is usable as `return keepFocus(button)`');
  });
});
