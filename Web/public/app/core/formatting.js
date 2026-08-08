import {
  makeRange,
  maxRange,
  clampRange,
  substringWithRange,
  lineBounds,
  paragraphRange,
} from './range.js';
import {
  parseImageTag,
  imageReference,
  escapeLabel,
  encodeDestination,
} from './image-tag.js';

// ── Exported constants ───────────────────────────────────────────────────────

export const InlineStyle = Object.freeze({
  bold: 'bold',
  italic: 'italic',
  underline: 'underline',
  strikethrough: 'strikethrough',
  inlineCode: 'inlineCode',
});

export const ListStyle = Object.freeze({
  bulleted: 'bulleted',
  numbered: 'numbered',
  task: 'task',
});

// ── Public API ───────────────────────────────────────────────────────────────

/**
 * Toggle an inline style around the selection.
 * @param {string} style - One of the InlineStyle constants.
 * @param {string} text
 * @param {{ location: number, length: number }} selection
 * @returns {{ text: string, selection: { location: number, length: number } }}
 */
export function toggleInline(style, text, selection) {
  const sel = clampRange(selection, text.length);
  const selectedContent = substringWithRange(text, sel);
  const markers = markersForStyle(style, selectedContent);
  const openingLength = markers.opening.length;
  const closingLength = markers.closing.length;

  // Empty selection: insert placeholder text wrapped in the style markers.
  if (sel.length === 0) {
    const placeholder = placeholderText(style);
    const rep = markers.opening + placeholder + markers.closing;
    return replacing(text, sel, rep, makeRange(sel.location + openingLength, placeholder.length));
  }

  // Selected text is a combined bold+italic run (***...*** or ___...___): remove
  // just this style's markers and keep the remaining level of emphasis.
  const combinedResult = removingStyleFromCombinedRun(style, selectedContent);
  if (combinedResult !== null) {
    return replacing(
      text, sel, combinedResult.text,
      makeRange(sel.location + combinedResult.contentOffset, combinedResult.contentLength)
    );
  }

  // Selected text uses an alternate marker for this style (e.g. _word_ for italic).
  const alternateContent = unwrappedEquivalentStyle(style, selectedContent);
  if (alternateContent !== null) {
    return replacing(text, sel, alternateContent, makeRange(sel.location, alternateContent.length));
  }

  // Selection is the content inside a ***...*** run that uses markers outside it.
  const surroundingCombined = removingStyleFromSurroundingCombinedRun(style, text, sel);
  if (surroundingCombined !== null) return surroundingCombined;

  // Inline code only: selection sits inside a padded code span (`` ` content ` ``).
  if (style === InlineStyle.inlineCode) {
    const paddedResult = unwrappingSurroundingPaddedCodeSpan(text, sel);
    if (paddedResult !== null) return paddedResult;
  }

  // Inline code only: the selected text is itself a code span—unwrap it.
  if (style === InlineStyle.inlineCode) {
    const unwrapped = unwrappedCodeSpan(selectedContent);
    if (unwrapped !== null) {
      return replacing(text, sel, unwrapped, makeRange(sel.location, unwrapped.length));
    }
  }

  // Selected text already includes the opening and closing markers.
  if (sel.length >= openingLength + closingLength) {
    const innerLength = sel.length - openingLength - closingLength;
    if (
      selectedContent.slice(0, openingLength) === markers.opening &&
      selectedContent.slice(openingLength + innerLength) === markers.closing &&
      markerIsIsolated(selectedContent, makeRange(0, openingLength), markers.opening) &&
      markerIsIsolated(selectedContent, makeRange(openingLength + innerLength, closingLength), markers.closing)
    ) {
      const content = selectedContent.slice(openingLength, openingLength + innerLength);
      return replacing(text, sel, content, makeRange(sel.location, innerLength));
    }
  }

  // Markers sit immediately outside the selection.
  const openingRange = makeRange(sel.location - openingLength, openingLength);
  const closingRange = makeRange(maxRange(sel), closingLength);
  if (
    openingRange.location >= 0 &&
    maxRange(closingRange) <= text.length &&
    substringWithRange(text, openingRange) === markers.opening &&
    substringWithRange(text, closingRange) === markers.closing &&
    markerIsIsolated(text, openingRange, markers.opening) &&
    markerIsIsolated(text, closingRange, markers.closing)
  ) {
    // Delete closing first (higher offset), then opening, to keep lower offsets valid.
    let result = text.slice(0, closingRange.location) + text.slice(maxRange(closingRange));
    result = result.slice(0, openingRange.location) + result.slice(maxRange(openingRange));
    return { text: result, selection: makeRange(sel.location - openingLength, sel.length) };
  }

  // Alternate-marker equivalent (e.g. __word__) sits outside the selection.
  const surroundingEquivalent = removingSurroundingEquivalentStyle(style, text, sel);
  if (surroundingEquivalent !== null) return surroundingEquivalent;

  // Wrap: for inline code keep the full selected content (including boundary
  // whitespace); for all other styles move leading/trailing whitespace outside
  // the markers so the rendered output doesn't include extra spaces.
  const boundaryParts =
    style === InlineStyle.inlineCode
      ? { leading: '', content: selectedContent, trailing: '' }
      : splitBoundaryWhitespace(selectedContent);

  if (boundaryParts.content === '') {
    return { text, selection: sel };
  }

  // Code spans require a padding space when the content starts/ends with a
  // backtick or when it is entirely surrounded by spaces, so that CommonMark
  // parsers recognise the span boundary correctly.
  const contentTrimmed = boundaryParts.content.trim();
  const contentStartsAndEndsWithWhitespace =
    /^\s/.test(boundaryParts.content) &&
    /\s$/.test(boundaryParts.content) &&
    contentTrimmed.length > 0;

  const needsCodePadding =
    style === InlineStyle.inlineCode &&
    (boundaryParts.content.startsWith('`') ||
      boundaryParts.content.endsWith('`') ||
      contentStartsAndEndsWithWhitespace);

  const padding = needsCodePadding ? ' ' : '';
  const rep =
    boundaryParts.leading +
    markers.opening +
    padding +
    boundaryParts.content +
    padding +
    markers.closing +
    boundaryParts.trailing;

  return replacing(
    text, sel, rep,
    makeRange(
      sel.location + boundaryParts.leading.length + openingLength + padding.length,
      boundaryParts.content.length
    )
  );
}

/**
 * Apply a heading level to the line(s) containing the selection.
 * Level 0 removes any existing heading marker.
 */
export function applyHeading(level, text, selection) {
  const clampedLevel = Math.min(Math.max(level, 0), 6);
  const lines = selectedLines(text, selection);
  const rep = clampedLevel === 0 ? '' : '#'.repeat(clampedLevel) + ' ';
  const edits = lines.map((line) => {
    const marker = headingMarker(line.content);
    return {
      range: makeRange(line.contentRange.location + marker.location, marker.length),
      replacement: rep,
    };
  });
  return applyingEdits(edits, text, selection);
}

/**
 * Toggle a list style on/off for every line in the selection.
 * If all non-empty lines already carry the requested style, remove it;
 * otherwise apply it, replacing any other existing list marker.
 */
export function toggleList(style, text, selection) {
  const lines = selectedLines(text, selection);
  const nonemptyLines = lines.filter((l) => l.content.trim() !== '');
  const shouldRemove =
    nonemptyLines.length > 0 &&
    nonemptyLines.every((l) => {
      const m = listMarker(l.content);
      return m !== null && m.style === style;
    });

  let itemNumber = 1;
  const edits = [];
  for (const line of lines) {
    if (line.content.trim() === '' && lines.length > 1) continue;

    const existing = listMarker(line.content);
    const oldMarkerRange =
      existing !== null
        ? existing.range
        : makeRange(indentationLength(line.content), 0);

    let rep;
    if (shouldRemove) {
      if (existing === null || existing.style !== style) continue;
      rep = '';
    } else {
      switch (style) {
        case ListStyle.bulleted:
          rep = '- ';
          break;
        case ListStyle.numbered:
          rep = `${itemNumber}. `;
          itemNumber += 1;
          break;
        case ListStyle.task:
          rep = '- [ ] ';
          break;
        default:
          rep = '';
      }
    }

    edits.push({
      range: makeRange(
        line.contentRange.location + oldMarkerRange.location,
        oldMarkerRange.length
      ),
      replacement: rep,
    });
  }

  return applyingEdits(edits, text, selection);
}

/** Toggle blockquote markers on/off for every line in the selection. */
export function toggleQuote(text, selection) {
  const lines = selectedLines(text, selection);
  const nonemptyLines = lines.filter((l) => l.content.trim() !== '');
  const shouldRemove =
    nonemptyLines.length > 0 && nonemptyLines.every((l) => quoteMarker(l.content).length > 0);

  const edits = [];
  for (const line of lines) {
    if (line.content.trim() === '' && lines.length > 1) continue;

    const marker = quoteMarker(line.content);
    const indentLen = indentationLength(line.content);
    edits.push({
      range: makeRange(
        line.contentRange.location + (marker.length > 0 ? marker.location : indentLen),
        marker.length
      ),
      replacement: shouldRemove ? '' : '> ',
    });
  }

  return applyingEdits(edits, text, selection);
}

/**
 * Wrap the lines covered by the selection in a fenced code block.
 * The fence length is always longer than the longest backtick run in the
 * selected content, so nested code blocks are handled correctly.
 */
export function wrapCodeBlock(text, selection) {
  const sel = clampRange(selection, text.length);

  if (sel.length === 0) {
    const needsLeadingNewline = sel.location > 0 && text[sel.location - 1] !== '\n';
    const needsTrailingNewline = sel.location < text.length;
    const leadingNewline = needsLeadingNewline ? '\n' : '';
    const trailingNewline = needsTrailingNewline ? '\n' : '';
    const rep = `${leadingNewline}\`\`\`\n\n\`\`\`${trailingNewline}`;
    return replacing(text, sel, rep, makeRange(sel.location + leadingNewline.length + 4, 0));
  }

  const lineProbe = makeRange(sel.location, Math.max(0, sel.length - 1));
  const blockRange = paragraphRange(text, lineProbe);
  const selectedText = substringWithRange(text, blockRange);
  const fence = codeFence(selectedText);
  const endsWithNewline = selectedText.endsWith('\n');
  const rep = endsWithNewline
    ? `${fence}\n${selectedText}${fence}\n`
    : `${fence}\n${selectedText}\n${fence}`;

  return replacing(text, blockRange, rep, makeRange(sel.location + fence.length + 1, sel.length));
}

/**
 * Insert a newline, continuing the current list item or blockquote if the
 * cursor is at the end of a non-empty continuation line.  An empty list item
 * (marker with no content) removes the marker instead of adding another item.
 */
export function insertNewline(text, selection) {
  const sel = clampRange(selection, text.length);

  if (sel.length !== 0) {
    return replacing(text, sel, '\n', makeRange(sel.location + 1, 0));
  }

  const { lineStart, contentsEnd } = lineBounds(text, sel.location);
  const contentRange = makeRange(lineStart, contentsEnd - lineStart);
  const line = substringWithRange(text, contentRange);

  const continuation = continuationInfo(line);
  if (
    continuation === null ||
    sel.location < contentRange.location + continuation.markerRange.length
  ) {
    return replacing(text, sel, '\n', makeRange(sel.location + 1, 0));
  }

  const contentAfterMarker = line.slice(continuation.markerRange.length);
  if (contentAfterMarker.trim() === '') {
    // Empty list item: remove the marker rather than continuing the list.
    const markerRange = makeRange(contentRange.location, continuation.markerRange.length);
    return replacing(text, markerRange, '', makeRange(contentRange.location, 0));
  }

  const rep = '\n' + continuation.nextPrefix;
  return replacing(text, sel, rep, makeRange(sel.location + rep.length, 0));
}

/**
 * Insert a Markdown inline link, escaping the label and encoding the
 * destination so the result is valid Markdown and round-trips correctly.
 *
 * @param {string} destination - The raw URL (not yet percent-encoded).
 * @param {string} text
 * @param {{ location: number, length: number }} selection
 */
export function insertLink(destination, text, selection) {
  const sel = clampRange(selection, text.length);
  const label = sel.length > 0 ? substringWithRange(text, sel) : 'link text';
  const escapedLabel = escapeLabel(label);
  const encodedDestination = encodeDestination(destination);
  const rep = `[${escapedLabel}](${encodedDestination})`;
  return replacing(text, sel, rep, makeRange(sel.location + 1, escapedLabel.length));
}

/**
 * Insert an image reference at the caret.
 *
 * Used by both routes into the document — a file copied into the assets folder
 * and a URL typed by hand — so the two produce identical text.
 *
 * @param {string} destination - The raw URL or relative path (not yet encoded).
 * @param {string} altText - Falls back to the selected text, then to a stub.
 */
export function insertImage(destination, altText, text, selection) {
  const sel = clampRange(selection, text.length);
  const selected = sel.length > 0 ? substringWithRange(text, sel) : '';
  const label = altText || selected || 'image';
  const rep = imageReference({ destination, altText: label });
  // Select the alt text so it can be typed straight over.
  return replacing(text, sel, rep, makeRange(sel.location + 2, escapeLabel(label).length));
}

/**
 * Set or clear the pixel size of the image written at `range`.
 *
 * A sized image cannot be Markdown — there is no syntax for it — so this
 * converts between the two forms in both directions: adding a size rewrites
 * `![alt](src)` as `<img …>`, and clearing it turns the tag back into
 * Markdown. Anything else is left untouched, so a stale range from a document
 * that has since been edited can never corrupt it.
 *
 * @param {{ width: number|null, height: number|null }} size
 */
export function setImageSize(text, range, size) {
  const sel = clampRange(range, text.length);
  const image = readImage(text, sel);
  if (image === null) return { text, selection: sel };

  const rep = imageReference({
    destination: image.destination,
    altText: image.altText,
    width: size.width,
    height: size.height,
  });
  // Keep the image selected: the size fields are driven by the selection, so
  // dropping it on every keystroke would make them unusable.
  return replacing(text, sel, rep, makeRange(sel.location, rep.length));
}

/**
 * Read the image reference occupying exactly `range`, in either form.
 * Returns null if that text is not one image and nothing else.
 */
export function readImage(text, range) {
  const sel = clampRange(range, text.length);
  const source = substringWithRange(text, sel);
  if (source.startsWith('<')) {
    const tag = parseImageTag(text, sel.location, maxRange(sel));
    return tag !== null && tag.end === maxRange(sel) ? tag : null;
  }
  const markdown = /^!\[((?:[^\[\]\\]|\\[\s\S])*)\]\(([^()\s]*)\)$/.exec(source);
  if (markdown === null) return null;
  return {
    destination: markdown[2],
    altText: markdown[1].replace(/\\([\s\S])/g, '$1'),
    width: null,
    height: null,
  };
}

/**
 * Insert a `***` horizontal rule, adding newlines around it as needed so it
 * always occupies its own line.
 */
export function insertHorizontalRule(text, selection) {
  const sel = clampRange(selection, text.length);
  const needsLeadingNewline = sel.location > 0 && text[sel.location - 1] !== '\n';
  const needsTrailingNewline =
    maxRange(sel) < text.length && text[maxRange(sel)] !== '\n';
  const rep =
    (needsLeadingNewline ? '\n' : '') + '***\n' + (needsTrailingNewline ? '\n' : '');
  return replacing(text, sel, rep, makeRange(sel.location + rep.length, 0));
}

// ── Private helpers ──────────────────────────────────────────────────────────

function replacing(text, range, replacement, selection) {
  const newText =
    text.slice(0, range.location) + replacement + text.slice(maxRange(range));
  return { text: newText, selection };
}

function applyingEdits(edits, text, selection) {
  const sel = clampRange(selection, text.length);

  const sorted = [...edits].sort((a, b) => {
    if (a.range.location !== b.range.location) return a.range.location - b.range.location;
    return a.range.length - b.range.length;
  });

  let result = text;
  for (let i = sorted.length - 1; i >= 0; i--) {
    const { range, replacement } = sorted[i];
    result = result.slice(0, range.location) + replacement + result.slice(maxRange(range));
  }

  let start = sel.location;
  let end = maxRange(sel);
  let accumulatedDelta = 0;

  for (const edit of sorted) {
    const adjustedRange = makeRange(edit.range.location + accumulatedDelta, edit.range.length);
    const repLength = edit.replacement.length;
    start = mapPosition(start, adjustedRange, repLength);
    end = mapPosition(end, adjustedRange, repLength);
    accumulatedDelta += repLength - edit.range.length;
  }

  return { text: result, selection: makeRange(start, Math.max(0, end - start)) };
}

function mapPosition(position, editRange, replacementLength) {
  if (position < editRange.location) return position;
  if (editRange.length === 0) return position + replacementLength;
  if (position >= maxRange(editRange)) return position + replacementLength - editRange.length;
  return editRange.location + replacementLength;
}

function selectedLines(text, selection) {
  const sel = clampRange(selection, text.length);

  if (text.length === 0) {
    return [{ content: '', contentRange: makeRange(0, 0) }];
  }

  const lineProbe =
    sel.length > 0
      ? makeRange(sel.location, Math.max(0, sel.length - 1))
      : sel;

  const selectedLineRange = paragraphRange(text, lineProbe);

  if (selectedLineRange.length === 0) {
    return [{ content: '', contentRange: makeRange(selectedLineRange.location, 0) }];
  }

  const lines = [];
  let location = selectedLineRange.location;
  const rangeEnd = maxRange(selectedLineRange);

  while (location < rangeEnd) {
    const { lineStart, lineEnd, contentsEnd } = lineBounds(text, location);
    const contentRange = makeRange(lineStart, contentsEnd - lineStart);
    lines.push({ content: substringWithRange(text, contentRange), contentRange });
    location = Math.max(lineEnd, location + 1);
  }

  return lines;
}

/** Returns the range of the heading marker (e.g. "## ") within the line. */
function headingMarker(line) {
  const r = firstMatchRange(/^([ \t]*)(#{1,6}[ \t]+)/, line, 2);
  return r !== null ? r : makeRange(indentationLength(line), 0);
}

/** Returns the range of the blockquote marker ("> ") within the line. */
function quoteMarker(line) {
  const r = firstMatchRange(/^([ \t]*)(>[ \t]?)/, line, 2);
  return r !== null ? r : makeRange(indentationLength(line), 0);
}

/**
 * Returns the range and style of the list marker at the start of `line`,
 * or null when the line has no list marker.
 */
function listMarker(line) {
  const patterns = [
    { re: /^([ \t]*)([-+*][ \t]+\[[ xX]\][ \t]+)/, style: ListStyle.task },
    { re: /^([ \t]*)(\d+[.)][ \t]+)/, style: ListStyle.numbered },
    { re: /^([ \t]*)([-+*][ \t]+)/, style: ListStyle.bulleted },
  ];
  for (const { re, style } of patterns) {
    const r = firstMatchRange(re, line, 2);
    if (r !== null) return { range: r, style };
  }
  return null;
}

/** Number of leading space/tab characters in `line`. */
function indentationLength(line) {
  let length = 0;
  while (length < line.length) {
    const ch = line.charCodeAt(length);
    if (ch !== 0x20 && ch !== 0x09) break;
    length += 1;
  }
  return length;
}

/**
 * Given a line, returns the marker range covering the continuation prefix
 * (full match) and the string to prepend to the next line, or null if the
 * line has no recognised continuation pattern.
 */
function continuationInfo(line) {
  // Task list continuation must be checked before plain bullet.
  const taskMatch = /^([ \t]*(?:>[ \t]?)*)([-+*][ \t]+\[[ xX]\][ \t]+)/.exec(line);
  if (taskMatch) {
    return {
      markerRange: makeRange(0, taskMatch[0].length),
      nextPrefix: taskMatch[1] + '- [ ] ',
    };
  }

  const bulletMatch = /^([ \t]*(?:>[ \t]?)*)([-+*][ \t]+)/.exec(line);
  if (bulletMatch) {
    return {
      markerRange: makeRange(0, bulletMatch[0].length),
      nextPrefix: bulletMatch[1] + '- ',
    };
  }

  // Only match numbers up to 9 digits so that values exceeding the safe
  // continuation range (999 999 999) fall through to a plain newline.
  const numberedMatch = /^([ \t]*(?:>[ \t]?)*)(\d{1,9})([.)])([ \t]+)/.exec(line);
  if (numberedMatch) {
    const prefix = numberedMatch[1];
    const number = parseInt(numberedMatch[2], 10);
    const delimiter = numberedMatch[3];
    const spacing = numberedMatch[4];
    const nextNumber = number < 999999999 ? number + 1 : number;
    return {
      markerRange: makeRange(0, numberedMatch[0].length),
      nextPrefix: `${prefix}${nextNumber}${delimiter}${spacing}`,
    };
  }

  // Quote-only continuation (no list marker on the line).
  const quoteOnlyMatch = /^([ \t]*(?:>[ \t]?)+)/.exec(line);
  if (quoteOnlyMatch) {
    return {
      markerRange: makeRange(0, quoteOnlyMatch[0].length),
      nextPrefix: quoteOnlyMatch[1],
    };
  }

  return null;
}

/**
 * Returns the opening/closing markers for an inline style.
 * For inline code the delimiter length is one more than the longest
 * consecutive backtick run inside `content`, so the span is always parseable.
 */
function markersForStyle(style, content) {
  if (style !== InlineStyle.inlineCode) {
    return defaultMarkersForStyle(style);
  }
  const run = longestBacktickRun(content);
  const delimiter = '`'.repeat(Math.max(1, run + 1));
  return { opening: delimiter, closing: delimiter };
}

function defaultMarkersForStyle(style) {
  switch (style) {
    case InlineStyle.bold:          return { opening: '**', closing: '**' };
    case InlineStyle.italic:        return { opening: '*',  closing: '*'  };
    case InlineStyle.underline:     return { opening: '<u>', closing: '</u>' };
    case InlineStyle.strikethrough: return { opening: '~~', closing: '~~' };
    case InlineStyle.inlineCode:    return { opening: '`',  closing: '`'  };
  }
}

/** Fenced code block fence: at least 3 backticks, always longer than any run in content. */
function codeFence(content) {
  return '`'.repeat(Math.max(3, longestBacktickRun(content) + 1));
}

function longestBacktickRun(text) {
  let longest = 0;
  let current = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 0x60) {
      current += 1;
      if (current > longest) longest = current;
    } else {
      current = 0;
    }
  }
  return longest;
}

/**
 * If `text` is a complete code span (backtick-delimited), return the
 * unpadded inner content; otherwise return null.
 */
function unwrappedCodeSpan(text) {
  let openingLength = 0;
  while (openingLength < text.length && text.charCodeAt(openingLength) === 0x60) {
    openingLength += 1;
  }
  if (openingLength === 0 || text.length <= openingLength * 2) return null;

  const closingStart = text.length - openingLength;
  if (text.slice(closingStart) !== '`'.repeat(openingLength)) return null;

  let content = text.slice(openingLength, closingStart);
  // CommonMark: strip exactly one leading and trailing space when the content
  // starts and ends with a space but is not entirely spaces.
  if (
    content.length >= 2 &&
    content.charCodeAt(0) === 0x20 &&
    content.charCodeAt(content.length - 1) === 0x20 &&
    content.trim().length > 0
  ) {
    content = content.slice(1, -1);
  }
  return content;
}

/**
 * When the selected text is a *** / ___ run with both bold and italic,
 * remove just the markers for `style` and return the result string plus the
 * new content offset and length, or null if this pattern doesn't apply.
 */
function removingStyleFromCombinedRun(style, text) {
  if (style !== InlineStyle.bold && style !== InlineStyle.italic) return null;
  if (text.length === 0) return null;

  const markerChar = text.charCodeAt(0);
  if (markerChar !== 0x2a && markerChar !== 0x5f) return null; // * or _

  let openingRun = 0;
  while (openingRun < text.length && text.charCodeAt(openingRun) === markerChar) {
    openingRun += 1;
  }
  let closingRun = 0;
  while (closingRun < text.length && text.charCodeAt(text.length - closingRun - 1) === markerChar) {
    closingRun += 1;
  }
  if (openingRun !== 3 || closingRun !== 3 || text.length <= openingRun + closingRun) return null;

  const markersToRemove = style === InlineStyle.bold ? 2 : 1;
  const remainingMarkers = 3 - markersToRemove;
  const content = text.slice(openingRun, text.length - closingRun);
  const marker = String.fromCharCode(markerChar).repeat(remainingMarkers);
  return { text: marker + content + marker, contentOffset: remainingMarkers, contentLength: content.length };
}

/**
 * When `text` is wrapped in an alternate marker for `style` (e.g. `_word_`
 * when the canonical italic marker is `*`), return the inner content.
 */
function unwrappedEquivalentStyle(style, text) {
  for (const markers of alternateMarkersForStyle(style)) {
    const oLen = markers.opening.length;
    const cLen = markers.closing.length;
    if (text.length <= oLen + cLen) continue;
    const openRange = makeRange(0, oLen);
    const closeRange = makeRange(text.length - cLen, cLen);
    if (
      substringWithRange(text, openRange) === markers.opening &&
      substringWithRange(text, closeRange) === markers.closing &&
      markerIsIsolated(text, openRange, markers.opening) &&
      markerIsIsolated(text, closeRange, markers.closing)
    ) {
      return text.slice(oLen, text.length - cLen);
    }
  }
  return null;
}

/**
 * When the selection is the plain content of a ***...*** run and the three-
 * character markers sit just outside it, shrink the surrounding markers by
 * removing this style's contribution.
 */
function removingStyleFromSurroundingCombinedRun(style, source, selection) {
  if (style !== InlineStyle.bold && style !== InlineStyle.italic) return null;
  if (selection.location < 3 || maxRange(selection) + 3 > source.length) return null;

  const markerChar = source.charCodeAt(selection.location - 1);
  if (markerChar !== 0x2a && markerChar !== 0x5f) return null;

  const openingRange = makeRange(selection.location - 3, 3);
  const closingRange = makeRange(maxRange(selection), 3);
  for (let k = 0; k < 3; k++) {
    if (
      source.charCodeAt(openingRange.location + k) !== markerChar ||
      source.charCodeAt(closingRange.location + k) !== markerChar
    ) {
      return null;
    }
  }

  const markersToRemove = style === InlineStyle.bold ? 2 : 1;
  const remainingMarkers = 3 - markersToRemove;
  const markerStr = String.fromCharCode(markerChar).repeat(remainingMarkers);

  // Replace closing first (higher offset), then opening.
  let result = source.slice(0, closingRange.location) + markerStr + source.slice(maxRange(closingRange));
  result = result.slice(0, openingRange.location) + markerStr + result.slice(maxRange(openingRange));
  return {
    text: result,
    selection: makeRange(selection.location - markersToRemove, selection.length),
  };
}

/**
 * When the selection is the content inside a padded code span
 * (backtick-run + space ... space + backtick-run) remove the delimiters and
 * the padding spaces, returning the unwrapped text.
 */
function unwrappingSurroundingPaddedCodeSpan(source, selection) {
  if (
    selection.location < 2 ||
    maxRange(selection) + 2 > source.length ||
    source.charCodeAt(selection.location - 1) !== 0x20 ||
    source.charCodeAt(maxRange(selection)) !== 0x20
  ) {
    return null;
  }

  let openingStart = selection.location - 1;
  while (openingStart > 0 && source.charCodeAt(openingStart - 1) === 0x60) {
    openingStart -= 1;
  }
  let closingEnd = maxRange(selection) + 1;
  while (closingEnd < source.length && source.charCodeAt(closingEnd) === 0x60) {
    closingEnd += 1;
  }

  const openingLength = selection.location - 1 - openingStart;
  const closingLength = closingEnd - maxRange(selection) - 1;
  if (openingLength === 0 || openingLength !== closingLength) return null;

  // Delete trailing (space + backticks) then leading (backticks + space).
  let result =
    source.slice(0, maxRange(selection)) + source.slice(maxRange(selection) + 1 + closingLength);
  result = result.slice(0, openingStart) + result.slice(openingStart + openingLength + 1);
  return { text: result, selection: makeRange(openingStart, selection.length) };
}

/**
 * When an alternate-marker equivalent (e.g. `__word__`) sits immediately
 * outside the selection, remove those markers.
 */
function removingSurroundingEquivalentStyle(style, source, selection) {
  for (const markers of alternateMarkersForStyle(style)) {
    const oLen = markers.opening.length;
    const cLen = markers.closing.length;
    const openingRange = makeRange(selection.location - oLen, oLen);
    const closingRange = makeRange(maxRange(selection), cLen);
    if (
      openingRange.location >= 0 &&
      maxRange(closingRange) <= source.length &&
      substringWithRange(source, openingRange) === markers.opening &&
      substringWithRange(source, closingRange) === markers.closing &&
      markerIsIsolated(source, openingRange, markers.opening) &&
      markerIsIsolated(source, closingRange, markers.closing)
    ) {
      let result = source.slice(0, closingRange.location) + source.slice(maxRange(closingRange));
      result = result.slice(0, openingRange.location) + result.slice(maxRange(openingRange));
      return {
        text: result,
        selection: makeRange(selection.location - oLen, selection.length),
      };
    }
  }
  return null;
}

/** Alternate markers recognised for a style (e.g. `__` for bold, `_` for italic). */
function alternateMarkersForStyle(style) {
  switch (style) {
    case InlineStyle.bold:   return [{ opening: '__', closing: '__' }];
    case InlineStyle.italic: return [{ opening: '_',  closing: '_'  }];
    default:                 return [];
  }
}

/** Split `text` into leading whitespace, trimmed content, and trailing whitespace. */
function splitBoundaryWhitespace(text) {
  const leadingMatch = text.match(/^\s*/u);
  const leading = leadingMatch ? leadingMatch[0] : '';
  const withoutLeading = text.slice(leading.length);
  const trailingMatch = withoutLeading.match(/\s*$/u);
  const trailing = trailingMatch ? trailingMatch[0] : '';
  const content = withoutLeading.slice(0, withoutLeading.length - trailing.length);
  return { leading, content, trailing };
}

function placeholderText(style) {
  switch (style) {
    case InlineStyle.bold:          return 'bold text';
    case InlineStyle.italic:        return 'italic text';
    case InlineStyle.underline:     return 'underlined text';
    case InlineStyle.strikethrough: return 'struck text';
    case InlineStyle.inlineCode:    return 'code';
  }
}

/**
 * A marker is "isolated" when the run of its repeated character does not
 * extend beyond the marker's range — i.e. there are no additional identical
 * characters immediately before or after it.  Markers whose characters are not
 * all the same (e.g. `<u>`) are always considered isolated.
 */
function markerIsIsolated(source, range, marker) {
  if (marker.length === 0) return true;
  const markerChar = marker.charCodeAt(0);
  for (let i = 1; i < marker.length; i++) {
    if (marker.charCodeAt(i) !== markerChar) return true;
  }
  const previousMatches =
    range.location > 0 && source.charCodeAt(range.location - 1) === markerChar;
  const nextMatches =
    maxRange(range) < source.length && source.charCodeAt(maxRange(range)) === markerChar;
  return !previousMatches && !nextMatches;
}

/**
 * Return the range of `captureGroup` within `string` for the first match of
 * `pattern`.  All patterns used here have the form `^(A)(B)…` so the start
 * of group N equals the sum of lengths of groups 1 … N-1.
 */
function firstMatchRange(pattern, string, captureGroup) {
  const regex = pattern instanceof RegExp ? pattern : new RegExp(pattern);
  const match = regex.exec(string);
  if (!match || match[captureGroup] == null) return null;
  let start = 0;
  for (let i = 1; i < captureGroup; i++) {
    start += match[i] ? match[i].length : 0;
  }
  return makeRange(start, match[captureGroup].length);
}
