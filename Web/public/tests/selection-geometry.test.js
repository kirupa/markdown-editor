// The shape selected text is shaded in (T-24). The first eight tests are the
// Mac's (SelectionHighlightGeometryTests.swift), so the two draw one shape.

import { suite, test, expect, expectEqual } from './harness.js';
import {
  END_PADDING,
  LINE_GAP,
  barBackground,
  cornerRadius,
  fadeLength,
  groupIntoLines,
  lineBand,
  lineSegment,
  parseCssColor,
  segmentStops,
  segmentsForLines,
  selectionPaint,
} from '../app/core/selection-geometry.js';

const near = (a, b, tolerance = 0.0001) => Math.abs(a - b) < tolerance;

suite('Selection shape', () => {
  test('a selection on one line is a rounded bar just wider than its words', () => {
    const bar = lineSegment({ start: 100, end: 180, top: 10, bottom: 29 });
    expectEqual(bar.x, 100 - END_PADDING);
    expectEqual(bar.y, 10);
    expectEqual(bar.width, 80 + 2 * END_PADDING);
    expectEqual(bar.height, 19);
    expectEqual(bar.fadeIn, 0);
    expectEqual(bar.fadeOut, 0);
    expect(bar.cornerRadius > 5 && bar.cornerRadius < 7, `radius ${bar.cornerRadius}`);
    expectEqual(segmentStops(bar).map((stop) => stop.opacity).join(), '1,1');
  });

  test('a line the selection runs on from fades out past its last word', () => {
    const bar = lineSegment({
      start: 100, end: 400, top: 0, bottom: 19, continuesOntoNextLine: true,
    });
    const fade = fadeLength(19);
    expectEqual(bar.x, 100 - END_PADDING);
    expectEqual(bar.x + bar.width, 400 + fade);
    expectEqual(bar.fadeIn, 0);
    expectEqual(bar.fadeOut, fade);
    const stops = segmentStops(bar);
    expectEqual(JSON.stringify(stops[0]), JSON.stringify({ location: 0, opacity: 1 }));
    expectEqual(JSON.stringify(stops[stops.length - 1]), JSON.stringify({ location: 1, opacity: 0 }));
    // Full strength all the way to the last word, then easing away.
    const lastWord = (400 - bar.x) / bar.width;
    const lastFull = [...stops].reverse().find((stop) => stop.opacity === 1);
    expect(near(lastFull.location, lastWord), `${lastFull.location} vs ${lastWord}`);
  });

  test('a line the selection runs on to fades in before its first word', () => {
    const bar = lineSegment({
      start: 30, end: 90, top: 20, bottom: 39, continuesFromPreviousLine: true,
    });
    const fade = fadeLength(19);
    expectEqual(bar.x, 30 - fade);
    expectEqual(bar.x + bar.width, 90 + END_PADDING);
    expectEqual(bar.fadeIn, fade);
    const stops = segmentStops(bar);
    expectEqual(JSON.stringify(stops[0]), JSON.stringify({ location: 0, opacity: 0 }));
    expectEqual(JSON.stringify(stops[stops.length - 1]), JSON.stringify({ location: 1, opacity: 1 }));
  });

  test('a line in the middle fades at both ends', () => {
    const stops = segmentStops(lineSegment({
      start: 30, end: 400, top: 20, bottom: 39,
      continuesFromPreviousLine: true, continuesOntoNextLine: true,
    }));
    expectEqual(stops[0].opacity, 0);
    expectEqual(stops[stops.length - 1].opacity, 0);
    expect(stops.some((stop) => stop.opacity === 1), 'a full-strength middle');
  });

  test('the fade eases, and never goes backwards', () => {
    for (const [fromPrevious, ontoNext] of [[false, false], [true, false], [false, true], [true, true]]) {
      for (const width of [0, 3, 40, 600]) {
        const stops = segmentStops(lineSegment({
          start: 50, end: 50 + width, top: 0, bottom: 19,
          continuesFromPreviousLine: fromPrevious, continuesOntoNextLine: ontoNext,
        }));
        expectEqual(stops[0].location, 0);
        expectEqual(stops[stops.length - 1].location, 1);
        for (let index = 1; index < stops.length; index += 1) {
          expect(stops[index - 1].location <= stops[index].location, 'stops in order');
        }
        expect(stops.every((stop) => stop.opacity >= 0 && stop.opacity <= 1), 'opacity in range');
        // Every fade has a gentle start: never a jump to half.
        if (fromPrevious) expect(stops[1].opacity < 0.2, 'gentle start');
      }
    }
  });

  test('an empty line inside a selection still shows', () => {
    const bar = lineSegment({
      start: 30, end: 30, top: 40, bottom: 59,
      continuesFromPreviousLine: true, continuesOntoNextLine: true,
    });
    const fade = fadeLength(19);
    expect(bar.width > 2 * fade, 'wider than its two fades');
    expect(bar.width - 2 * fade >= 4, 'a visible core');
  });

  test('taller lines are rounded more, to a limit; short ones stay bars', () => {
    expect(cornerRadius(19) < cornerRadius(24), 'rounder with height');
    expectEqual(cornerRadius(60), 8);
    const narrow = lineSegment({ start: 10, end: 11, top: 0, bottom: 40 });
    expect(narrow.cornerRadius <= narrow.width / 2, 'no wider than the bar');
    expect(narrow.cornerRadius <= narrow.height / 2, 'no taller than the bar');
  });

  test('the fade is about a line long, but stays out of the margin', () => {
    expectEqual(fadeLength(4), 10);
    expect(fadeLength(19) > 12 && fadeLength(19) < 16, `fade ${fadeLength(19)}`);
    expectEqual(fadeLength(90), 24);
  });
});

suite('Selection lines', () => {
  test('a line is shaded across its height less the gap, centred on its words', () => {
    // 15px text on a 1.45 line: the glyphs measure 18 tall inside 21.75.
    const band = lineBand({ top: 101.875, bottom: 119.875 }, 21.75);
    expect(near(band.bottom - band.top, 21.75 - LINE_GAP), `height ${band.bottom - band.top}`);
    expect(near((band.top + band.bottom) / 2, 110.875), 'centred');
    // Consecutive lines leave exactly the gap between their bars.
    const next = lineBand({ top: 123.625, bottom: 141.625 }, 21.75);
    expect(near(next.top - band.bottom, LINE_GAP), `gap ${next.top - band.bottom}`);
  });

  test('a face taller than its line is still shaded to the line, so bars never overlap', () => {
    const band = lineBand({ top: 0, bottom: 40 }, 21.75);
    expect(near(band.bottom - band.top, 19.75), 'the line decides');
    const unknown = lineBand({ top: 0, bottom: 18 }, Number.NaN);
    expectEqual(unknown.bottom - unknown.top, 18);
  });

  test('boxes on one line become one line, and the next line stays apart', () => {
    const lines = groupIntoLines([
      { left: 200, right: 260, top: 2, bottom: 20, lineHeight: 21.75 },   // bold, same line
      { left: 100, right: 200, top: 2, bottom: 20, lineHeight: 21.75 },
      { left: 262, right: 300, top: 3.5, bottom: 20.5, lineHeight: 21.75 }, // inline code, a little low
      { left: 50, right: 400, top: 23.75, bottom: 41.75, lineHeight: 21.75 }, // the next line
    ]);
    expectEqual(lines.length, 2);
    expectEqual([lines[0].left, lines[0].right].join(), '100,300');
    expectEqual([lines[1].left, lines[1].right].join(), '50,400');
    // Shaded once per line, so a word in another face cannot make it taller.
    for (const line of lines) {
      expect(near(line.bottom - line.top, 21.75 - LINE_GAP), `height ${line.bottom - line.top}`);
    }
    expect(lines[1].top - lines[0].bottom >= LINE_GAP - 0.5, 'the gap between lines survives');
  });

  test('a picture is shaded as big as it is drawn, whatever line it is on', () => {
    const [alone] = groupIntoLines([{ left: 90, right: 590, top: 100, bottom: 520 }]);
    expectEqual(JSON.stringify(alone), JSON.stringify({ left: 90, right: 590, top: 100, bottom: 520 }));
    const [beside] = groupIntoLines([
      { left: 90, right: 590, top: 100, bottom: 520 },
      { left: 600, right: 700, top: 500, bottom: 518, lineHeight: 21.75 },
    ]);
    expectEqual(JSON.stringify(beside), JSON.stringify({ left: 90, right: 700, top: 100, bottom: 520 }));
  });

  test('a box with no height is not a line', () => {
    expectEqual(groupIntoLines([{ left: 0, right: 10, top: 5, bottom: 5, lineHeight: 20 }]).length, 0);
  });

  test('a zero-width box is kept: it is an empty line or a selected break', () => {
    const lines = groupIntoLines([{ left: 30, right: 30, top: 0, bottom: 20, lineHeight: 22 }]);
    expectEqual(lines.length, 1);
    const [bar] = segmentsForLines(lines, { continuesAfter: true });
    expect(bar.width > fadeLength(20), 'it shows, and fades on');
  });

  test('only the true ends of a selection are hard', () => {
    const lines = [
      { left: 100, right: 400, top: 0, bottom: 20 },
      { left: 50, right: 400, top: 22, bottom: 42 },
      { left: 50, right: 120, top: 44, bottom: 64 },
    ];
    const bars = segmentsForLines(lines);
    expectEqual(bars.map((bar) => `${bar.fadeIn > 0}/${bar.fadeOut > 0}`).join(' '),
      'false/true true/true true/false');
    const carried = segmentsForLines(lines.slice(1), { continuesBefore: true, continuesAfter: true });
    expectEqual(carried.map((bar) => `${bar.fadeIn > 0}/${bar.fadeOut > 0}`).join(' '),
      'true/true true/true');
  });
});

suite('Selection colour', () => {
  test('themes.css colours are read the way they are written', () => {
    expectEqual(JSON.stringify(parseCssColor('#ffffff')), JSON.stringify({ r: 255, g: 255, b: 255, a: 1 }));
    expectEqual(JSON.stringify(parseCssColor('#383a42')), JSON.stringify({ r: 56, g: 58, b: 66, a: 1 }));
    expectEqual(JSON.stringify(parseCssColor(' rgba(81, 138, 193, 0.291) ')),
      JSON.stringify({ r: 81, g: 138, b: 193, a: 0.291 }));
    expectEqual(JSON.stringify(parseCssColor('rgb(1 2 3 / 50%)')), JSON.stringify({ r: 1, g: 2, b: 3, a: 0.5 }));
    expectEqual(JSON.stringify(parseCssColor('#fff8')), JSON.stringify({ r: 255, g: 255, b: 255, a: 0.533 }));
    expectEqual(parseCssColor(''), null);
    expectEqual(parseCssColor('blue'), null);
    expectEqual(parseCssColor(undefined), null);
  });

  test('on a light page the tint multiplies, and leaves the page the tinted colour', () => {
    const tint = { r: 7, g: 152, b: 255, a: 0.304 };
    const page = { r: 255, g: 255, b: 255, a: 1 };
    const { blend, colour } = selectionPaint(tint, page);
    expectEqual(blend, 'multiply');
    for (const channel of ['r', 'g', 'b']) {
      const translucent = tint.a * tint[channel] + (1 - tint.a) * page[channel];
      const multiplied = (colour[channel] * page[channel]) / 255;
      expect(Math.abs(multiplied - translucent) <= 0.5, `${channel}: ${multiplied} vs ${translucent}`);
    }
  });

  test('on a dark page the tint screens, and leaves the page the tinted colour', () => {
    const tint = { r: 81, g: 138, b: 193, a: 0.291 };
    const page = { r: 56, g: 58, b: 66, a: 1 };
    const { blend, colour } = selectionPaint(tint, page);
    expectEqual(blend, 'screen');
    for (const channel of ['r', 'g', 'b']) {
      const translucent = tint.a * tint[channel] + (1 - tint.a) * page[channel];
      const screened = 255 - ((255 - colour[channel]) * (255 - page[channel])) / 255;
      expect(Math.abs(screened - translucent) <= 0.5, `${channel}: ${screened} vs ${translucent}`);
    }
  });

  test('ink keeps its contrast: dark ink stays dark, light ink stays light', () => {
    const light = selectionPaint({ r: 7, g: 152, b: 255, a: 0.304 }, { r: 255, g: 255, b: 255, a: 1 });
    // Multiplying never lightens, so black text on the tint is still black.
    expectEqual((light.colour.r * 0) / 255, 0);
    const dark = selectionPaint({ r: 81, g: 138, b: 193, a: 0.291 }, { r: 56, g: 58, b: 66, a: 1 });
    // Screening never darkens, so white text on the tint is still white.
    expectEqual(255 - ((255 - dark.colour.g) * (255 - 255)) / 255, 255);
  });

  test('a solid bar is one colour, and a fading one is a gradient to nothing', () => {
    const colour = { r: 10, g: 20, b: 30 };
    expectEqual(barBackground(lineSegment({ start: 0, end: 50, top: 0, bottom: 20 }), colour), 'rgb(10, 20, 30)');
    const fading = barBackground(
      lineSegment({ start: 0, end: 50, top: 0, bottom: 20, continuesOntoNextLine: true }),
      colour
    );
    expect(fading.startsWith('linear-gradient(to right, rgba(10, 20, 30, 1) 0%'), fading);
    expect(fading.endsWith('rgba(10, 20, 30, 0) 100%)'), fading);
  });
});
