// The shape selected text is shaded in (T-24), the web's copy of
// Shared/Sources/MarkdownEditorUI/SelectionHighlightGeometry.swift.
//
// A line where the selection starts and stops is a rounded bar hugging the
// words. Where it carries on to the next line the bar runs a little past the
// last word and fades out, and the next line's bar fades in from a little
// before its first word — so a selection broken across lines still reads as
// one thing, and the only hard ends are where the selection really starts and
// stops.
//
// Pure: it is handed boxes the page has already measured and says what to
// draw. The measuring and the drawing are ui/selection-highlight.js.

/** Air between the ink and a hard end, so the first and last letters are not
 *  touching the edge of their own highlight. */
export const END_PADDING = 2;

/** Air between the bars of consecutive lines, so a paragraph's lines read as
 *  lines rather than one slab. */
export const LINE_GAP = 2;

/** About a third of the bar's height, so a line of body text and a heading
 *  look like the same object — and never so much that a tall line is a pill. */
export function cornerRadius(height) {
  return Math.min(Math.max(0, height) * 0.32, 8);
}

/** How far a bar runs past a line's end as it fades: most of a line's height,
 *  so it reads as the selection carrying on without reaching far into the
 *  margin. */
export function fadeLength(height) {
  return Math.min(Math.max(Math.max(0, height) * 0.75, 10), 24);
}

/**
 * The bar for the selected run from `start` to `end` on a line that stands
 * from `top` to `bottom`.
 *
 * `continuesFromPreviousLine` when the selection began on an earlier line;
 * `continuesOntoNextLine` when it runs on past this one, including when only
 * this line's break is selected. A run with no width — an empty line inside a
 * selection, or one that starts on a line's break — is still given a little,
 * so it shows.
 */
export function lineSegment({
  start,
  end,
  top,
  bottom,
  continuesFromPreviousLine = false,
  continuesOntoNextLine = false,
}) {
  const height = Math.max(0, bottom - top);
  const left = Math.min(start, end);
  const right = Math.max(left + Math.max(4, height * 0.3), Math.max(start, end));
  const fade = fadeLength(height);
  const x = left - (continuesFromPreviousLine ? fade : END_PADDING);
  const maxX = right + (continuesOntoNextLine ? fade : END_PADDING);
  const width = maxX - x;
  return {
    x,
    y: top,
    width,
    height,
    cornerRadius: Math.min(cornerRadius(height), width / 2),
    fadeIn: continuesFromPreviousLine ? fade : 0,
    fadeOut: continuesOntoNextLine ? fade : 0,
  };
}

// Smoothstep, sampled: a straight ramp shows a crease where it meets the flat
// part of the bar.
const EASE = [
  [0, 0],
  [0.25, 0.156],
  [0.5, 0.5],
  [0.75, 0.844],
  [1, 1],
];

/**
 * How strongly a bar is shaded along its length, left to right: full where it
 * is not fading, easing to nothing across a fade. Always starts at location 0
 * and ends at 1.
 */
export function segmentStops(segment) {
  const { width, fadeIn, fadeOut } = segment;
  if (!(width > 0)) {
    return [
      { location: 0, opacity: 1 },
      { location: 1, opacity: 1 },
    ];
  }
  const stops = [];
  if (fadeIn > 0) {
    for (const [t, opacity] of EASE) stops.push({ location: (t * fadeIn) / width, opacity });
  } else {
    stops.push({ location: 0, opacity: 1 });
  }
  if (fadeOut > 0) {
    for (let index = EASE.length - 1; index >= 0; index -= 1) {
      const [t, opacity] = EASE[index];
      stops.push({ location: 1 - (t * fadeOut) / width, opacity });
    }
  } else {
    stops.push({ location: 1, opacity: 1 });
  }
  return stops;
}

/**
 * The band a line of text is shaded across, from the box its glyphs measure
 * and the height of the line they sit on: the whole line, less the gap, and
 * centred where the glyphs are — which is where CSS centres them in the line.
 */
export function lineBand(glyphs, lineHeight) {
  const centre = (glyphs.top + glyphs.bottom) / 2;
  const height = Number.isFinite(lineHeight) && lineHeight > LINE_GAP
    ? lineHeight - LINE_GAP
    : glyphs.bottom - glyphs.top;
  return { top: centre - height / 2, bottom: centre + height / 2 };
}

/**
 * Boxes measured one text node at a time, gathered into the lines they sit on
 * and given the band each line is shaded across.
 *
 * A box with a `lineHeight` is glyphs — text, or a caret standing for a
 * selected break — and is shaded across its line (see lineBand), once per
 * line, from the union of the glyphs on it. A box without one is a picture,
 * shaded exactly as big as it is drawn.
 *
 * Two boxes are on the same line when they overlap by at least half the
 * shorter of the two: a word in a smaller face — inline code — sits a little
 * off its line's centre, but nowhere near the next line.
 */
export function groupIntoLines(boxes) {
  const sorted = boxes
    .filter((box) => box.bottom > box.top)
    .sort((a, b) => a.top - b.top || a.left - b.left);
  const lines = [];
  for (const box of sorted) {
    let line = lines[lines.length - 1];
    if (!line || !sameLine(line, box)) {
      line = {
        left: box.left,
        right: box.right,
        top: box.top,
        bottom: box.bottom,
        glyphs: null,
        lineHeight: Number.NaN,
        pictures: null,
      };
      lines.push(line);
    }
    line.left = Math.min(line.left, box.left);
    line.right = Math.max(line.right, box.right);
    line.top = Math.min(line.top, box.top);
    line.bottom = Math.max(line.bottom, box.bottom);
    if (box.lineHeight === undefined) {
      line.pictures = union(line.pictures, box);
    } else {
      line.glyphs = union(line.glyphs, box);
      if (Number.isFinite(box.lineHeight) && !(box.lineHeight <= line.lineHeight)) {
        line.lineHeight = box.lineHeight;
      }
    }
  }
  return lines.map((line) => {
    let top = Infinity;
    let bottom = -Infinity;
    if (line.glyphs) {
      const band = lineBand(line.glyphs, line.lineHeight);
      top = band.top;
      bottom = band.bottom;
    }
    if (line.pictures) {
      top = Math.min(top, line.pictures.top);
      bottom = Math.max(bottom, line.pictures.bottom);
    }
    return { left: line.left, right: line.right, top, bottom };
  });
}

function union(box, other) {
  if (!box) return { top: other.top, bottom: other.bottom };
  return { top: Math.min(box.top, other.top), bottom: Math.max(box.bottom, other.bottom) };
}

function sameLine(a, b) {
  const overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
  const shorter = Math.min(a.bottom - a.top, b.bottom - b.top);
  return overlap > 0 && overlap >= shorter / 2;
}

/**
 * One bar per line. Every line but the first carries on from the one before,
 * and every line but the last carries on to the next; `continuesBefore` and
 * `continuesAfter` say the selection also reaches past the first and last
 * lines given — lines not measured because they are off screen, or a break
 * selected at the very end.
 */
export function segmentsForLines(lines, { continuesBefore = false, continuesAfter = false } = {}) {
  return lines.map((line, index) =>
    lineSegment({
      start: line.left,
      end: line.right,
      top: line.top,
      bottom: line.bottom,
      continuesFromPreviousLine: index > 0 || continuesBefore,
      continuesOntoNextLine: index < lines.length - 1 || continuesAfter,
    })
  );
}

// ── colour ────────────────────────────────────────────────────────────────────

/**
 * Reads the colours themes.css writes: `#rgb`, `#rgba`, `#rrggbb`,
 * `#rrggbbaa`, and `rgb()`/`rgba()` with commas or spaces. Channels come back
 * 0–255 and alpha 0–1; anything else is null.
 */
export function parseCssColor(text) {
  if (typeof text !== 'string') return null;
  const value = text.trim().toLowerCase();
  const hex = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/.exec(value);
  if (hex) {
    let digits = hex[1];
    if (digits.length <= 4) digits = [...digits].map((d) => d + d).join('');
    const channel = (index) => parseInt(digits.slice(index * 2, index * 2 + 2), 16);
    return {
      r: channel(0),
      g: channel(1),
      b: channel(2),
      a: digits.length === 8 ? round(channel(3) / 255, 3) : 1,
    };
  }
  const functional = /^rgba?\(([^)]*)\)$/.exec(value);
  if (!functional) return null;
  const parts = functional[1].split(/[\s,/]+/).filter(Boolean);
  if (parts.length !== 3 && parts.length !== 4) return null;
  const channels = parts.slice(0, 3).map((part) =>
    part.endsWith('%') ? (parseFloat(part) / 100) * 255 : parseFloat(part)
  );
  const alphaPart = parts[3];
  const alpha = alphaPart === undefined
    ? 1
    : alphaPart.endsWith('%') ? parseFloat(alphaPart) / 100 : parseFloat(alphaPart);
  if (![...channels, alpha].every(Number.isFinite)) return null;
  const [r, g, b] = channels.map((c) => clamp(c, 0, 255));
  return { r, g, b, a: clamp(alpha, 0, 1) };
}

/**
 * How to paint a tint *over* text so it looks as it would *under* it.
 *
 * The page can only paint the shading on top of the words, and a translucent
 * wash on top would dim them. Blending instead keeps them: on a light page,
 * `multiply` by the colour the tint makes of the page, which leaves the page
 * exactly that colour and dark ink dark; on a dark page, `screen` by the colour
 * that lifts the page to it, which leaves light ink light. Both are exact on
 * the page itself; elsewhere — a code block, a critique mark, a picture — they
 * shade whatever is there by the same amount.
 */
export function selectionPaint(tint, page) {
  const target = (channel) => tint.a * tint[channel] + (1 - tint.a) * page[channel];
  const light = relativeLuminance(page) >= 0.5;
  const colour = {};
  for (const channel of ['r', 'g', 'b']) {
    const wanted = target(channel);
    const under = page[channel];
    const share = light
      ? under <= 0 ? 1 : wanted / under
      : under >= 255 ? 0 : (wanted - under) / (255 - under);
    colour[channel] = Math.round(clamp(share, 0, 1) * 255);
  }
  return { blend: light ? 'multiply' : 'screen', colour };
}

/** The CSS background for a bar: solid, or a gradient where it fades. */
export function barBackground(segment, colour) {
  const rgb = `${colour.r}, ${colour.g}, ${colour.b}`;
  const stops = segmentStops(segment);
  if (stops.every((stop) => stop.opacity >= 1)) return `rgb(${rgb})`;
  const list = stops
    .map((stop) => `rgba(${rgb}, ${round(stop.opacity, 3)}) ${round(stop.location * 100, 3)}%`)
    .join(', ');
  return `linear-gradient(to right, ${list})`;
}

function relativeLuminance({ r, g, b }) {
  const linear = (channel) => {
    const c = channel / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b);
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value));
}

function round(value, places) {
  const factor = 10 ** places;
  return Math.round(value * factor) / factor;
}
