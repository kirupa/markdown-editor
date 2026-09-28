// The faces the document and the critique can be set in (T-16 to T-20).

import { suite, test, expectEqual, expect } from './harness.js';
import {
  INITIAL_TYPEFACE,
  TYPEFACES,
  availableTypefaces,
  isTypeface,
  resolvedTypeface,
  typefaceByID,
  typefaceFamily,
} from '../app/ui/typefaces.js';

suite('Typefaces', () => {
  test('the ids are the Mac\u2019s raw values, so a choice means the same face on both', () => {
    expectEqual(
      TYPEFACES.map((face) => face.id).join(','),
      [
        'sans', 'architectsDaughter', 'caveat', 'indieFlower', 'patrickHand',
        'shadowsIntoLight', 'gloriaHallelujah', 'kalam', 'permanentMarker',
        'bradleyHand', 'markerFelt', 'noteworthy', 'chalkboard',
      ].join(',')
    );
    expectEqual(INITIAL_TYPEFACE, 'sans');
  });

  test('an unknown id is the system face, and is not mistaken for a choice', () => {
    expectEqual(typefaceByID('comicSans').id, 'sans');
    expectEqual(typefaceByID(null).id, 'sans');
    expect(!isTypeface('comicSans'), 'an unknown id is not a typeface');
    expect(isTypeface('patrickHand'), 'a known id is');
  });

  test('the system face and every bundled face are always offered', () => {
    const offered = availableTypefaces().map((face) => face.id);
    for (const face of TYPEFACES.filter((entry) => entry.bundled || entry.id === 'sans')) {
      expect(offered.includes(face.id), `${face.id} is offered`);
    }
    expectEqual(offered[0], 'sans', 'the system face heads the list');
  });

  test('a face this machine cannot draw resolves to the system face, at its size', () => {
    const offered = new Set(availableTypefaces().map((face) => face.id));
    for (const face of TYPEFACES) {
      const resolved = resolvedTypeface(face.id);
      expectEqual(resolved.id, offered.has(face.id) ? face.id : 'sans', face.id);
    }
    expectEqual(resolvedTypeface('caveat').scale, 1.28, 'a bundled face keeps its optical scale');
    expectEqual(resolvedTypeface('comicSans').scale, 1, 'the fallback draws at the size asked for');
  });

  test('a family falls back to the stack it is given', () => {
    expectEqual(typefaceFamily(typefaceByID('sans'), 'var(--me-text-font)'), 'var(--me-text-font)');
    expectEqual(
      typefaceFamily(typefaceByID('chalkboard'), 'var(--me-ui-font)'),
      '"Chalkboard SE", var(--me-ui-font)'
    );
  });
});
