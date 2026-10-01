// The size the document is drawn at (T-23).

import { suite, test, expectEqual } from './harness.js';
import {
  TEXT_SCALE_KEY,
  TEXT_SCALE_MAX,
  TEXT_SCALE_MIN,
  TEXT_SCALE_STEP,
  clampedTextScale,
  textScalePercent,
} from '../app/core/text-scale.js';

suite('Text scale', () => {
  test('the range and the key are the Mac\u2019s, so a size means the same on both', () => {
    expectEqual(TEXT_SCALE_KEY, 'editorTextScale');
    expectEqual(TEXT_SCALE_MIN, 0.75);
    expectEqual(TEXT_SCALE_MAX, 1.5);
    expectEqual(TEXT_SCALE_STEP, 0.05);
  });

  test('a size inside the range is kept, to the whole percent', () => {
    expectEqual(clampedTextScale(1.25), 1.25);
    expectEqual(clampedTextScale(0.8 + 0.05 * 4), 1, 'a slider\u2019s float drift is the stop it names');
    expectEqual(clampedTextScale(1.234), 1.23);
  });

  test('a size outside the range is brought to its nearest end', () => {
    expectEqual(clampedTextScale(0.5), 0.75);
    expectEqual(clampedTextScale(3), 1.5);
    expectEqual(clampedTextScale(-1), 0.75);
  });

  test('what localStorage hands back is read as the number it spells', () => {
    expectEqual(clampedTextScale('1.1'), 1.1);
    expectEqual(clampedTextScale('0.6'), 0.75);
  });

  test('nothing stored, or nonsense stored, is 100%', () => {
    expectEqual(clampedTextScale(null), 1);
    expectEqual(clampedTextScale(undefined), 1);
    expectEqual(clampedTextScale(''), 1);
    expectEqual(clampedTextScale('  '), 1);
    expectEqual(clampedTextScale('large'), 1);
    expectEqual(clampedTextScale(Number.NaN), 1);
    expectEqual(clampedTextScale(Number.POSITIVE_INFINITY), 1);
  });

  test('the readout is a whole percent', () => {
    expectEqual(textScalePercent(1), '100%');
    expectEqual(textScalePercent(0.75), '75%');
    expectEqual(textScalePercent(1.5), '150%');
    expectEqual(textScalePercent(1.1500000000000001), '115%');
  });
});
