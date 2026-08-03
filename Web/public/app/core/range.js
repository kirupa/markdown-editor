// Range primitives mirroring Foundation's NSRange.
//
// The macOS core is written against NSString, whose offsets are UTF-16 code
// units. JavaScript string indices are also UTF-16 code units, so offsets
// carry across the port unchanged and the two implementations agree
// character-for-character on astral-plane input.

/** @typedef {{ location: number, length: number }} Range */

/**
 * @param {number} location
 * @param {number} length
 * @returns {Range}
 */
export function makeRange(location, length) {
  return { location, length };
}

/** End offset of a range — Foundation's NSMaxRange. */
export function maxRange(range) {
  return range.location + range.length;
}

/** Overlap of two ranges, or a zero-length range when they do not overlap. */
export function intersectionRange(a, b) {
  const location = Math.max(a.location, b.location);
  const end = Math.min(maxRange(a), maxRange(b));
  return end <= location ? makeRange(0, 0) : makeRange(location, end - location);
}

/** Smallest range covering both inputs. */
export function unionRange(a, b) {
  const location = Math.min(a.location, b.location);
  const end = Math.max(maxRange(a), maxRange(b));
  return makeRange(location, end - location);
}

/** True when `offset` falls inside `range`. */
export function rangeContains(range, offset) {
  return offset >= range.location && offset < maxRange(range);
}

export function rangesEqual(a, b) {
  return a.location === b.location && a.length === b.length;
}

/** Confines a range to `[0, length]`, clamping both ends. */
export function clampRange(range, length) {
  const location = Math.min(Math.max(0, range.location), length);
  const span = Math.min(Math.max(0, range.length), length - location);
  return makeRange(location, span);
}

/** Substring addressed by a range, matching `NSString.substring(with:)`. */
export function substringWithRange(text, range) {
  return text.slice(range.location, maxRange(range));
}

/**
 * Line boundaries around `location`, mirroring
 * `NSString.getLineStart(_:end:contentsEnd:for:)`.
 *
 * `contentsEnd` excludes the line terminator and `end` includes it, so
 * `[contentsEnd, end)` is exactly the newline sequence. CRLF is treated as a
 * single terminator, as Foundation does.
 *
 * @returns {{ lineStart: number, lineEnd: number, contentsEnd: number }}
 */
export function lineBounds(text, location) {
  const length = text.length;
  const start = Math.min(Math.max(0, location), length);

  let lineStart = start;
  while (lineStart > 0 && !isLineTerminator(text.charCodeAt(lineStart - 1))) {
    lineStart -= 1;
  }

  let contentsEnd = start;
  while (contentsEnd < length && !isLineTerminator(text.charCodeAt(contentsEnd))) {
    contentsEnd += 1;
  }

  let lineEnd = contentsEnd;
  if (lineEnd < length) {
    const code = text.charCodeAt(lineEnd);
    lineEnd += 1;
    if (code === 0x0d && lineEnd < length && text.charCodeAt(lineEnd) === 0x0a) {
      lineEnd += 1;
    }
  }

  return { lineStart, lineEnd, contentsEnd };
}

function isLineTerminator(code) {
  return code === 0x0a || code === 0x0d || code === 0x2028 || code === 0x2029;
}

/**
 * Range of the paragraph (line including its terminator) containing `range`,
 * mirroring `NSString.paragraphRange(for:)`.
 */
export function paragraphRange(text, range) {
  const { lineStart } = lineBounds(text, range.location);
  let end = maxRange(range);
  let { lineEnd } = lineBounds(text, end);
  if (range.length > 0 && end > range.location) {
    const bounds = lineBounds(text, end - 1);
    lineEnd = bounds.lineEnd;
  }
  return makeRange(lineStart, lineEnd - lineStart);
}
