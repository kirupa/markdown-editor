import { suite, test, expectEqual } from './harness.js';
import { textReplacement } from '../app/core/text-difference.js';
import { makeRange } from '../app/core/range.js';

suite('Markdown text difference', () => {
  test('A single inserted character replaces only that position', () => {
    const result = textReplacement('Hello world', 'Hello, world', makeRange(5, 0));
    expectEqual(result, { range: makeRange(5, 0), replacement: ',' });
  });

  test('A replaced selection reports the selection range', () => {
    const result = textReplacement('Hello world', 'Hello there', makeRange(6, 5));
    expectEqual(result, { range: makeRange(6, 5), replacement: 'there' });
  });

  test('A deletion reports an empty replacement', () => {
    const result = textReplacement('Hello world', 'Hello', makeRange(5, 6));
    expectEqual(result, { range: makeRange(5, 6), replacement: '' });
  });

  test('A wrong requested range falls back to prefix and suffix matching', () => {
    // The rendered view reports a range that cannot explain the change, so the
    // shared prefix and suffix have to be measured instead.
    const result = textReplacement('abcdef', 'abXYef', makeRange(0, 0));
    expectEqual(result, { range: makeRange(2, 2), replacement: 'XY' });
  });

  test('Identical text honors the requested range rather than detecting a no-op', () => {
    // The prefix and suffix around the requested range match, so the fast path
    // takes the caller at its word and reports a self-replacement. The macOS
    // original behaves the same way; callers that care filter no-ops
    // themselves.
    const result = textReplacement('same', 'same', makeRange(0, 4));
    expectEqual(result, { range: makeRange(0, 4), replacement: 'same' });
  });

  test('Unrelated trailing text is left out of the replacement', () => {
    const result = textReplacement(
      'keep this\nedit me\nkeep that',
      'keep this\nedited\nkeep that',
      makeRange(10, 7)
    );
    expectEqual(result, { range: makeRange(10, 7), replacement: 'edited' });
  });

  test('Replacing the whole document is handled', () => {
    const result = textReplacement('old', 'brand new', makeRange(0, 3));
    expectEqual(result, { range: makeRange(0, 3), replacement: 'brand new' });
  });
});
