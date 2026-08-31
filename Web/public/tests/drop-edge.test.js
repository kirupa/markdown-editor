import { suite, test, expect, expectEqual } from './harness.js';
import { chooseDropEdge } from '../app/ui/image-selection.js';

// Where a dragged picture would land, decided without a browser.
//
// This is the decision the macOS build got wrong twice, and neither mistake
// shows up in a screenshot: it offered a drop in the middle of a word, and it
// offered a drop at a place releasing then declined to use. Both were only
// visible by asking the geometry directly, which is why it is separated from
// the DOM here.
suite('Choosing where a dragged picture lands', () => {
  // Three stacked lines, 20pt tall, with a paragraph's worth of source behind
  // each: [0,10), [11,21), [22,32).
  const blocks = [
    { top: 0, bottom: 20, renderedStart: 0, renderedEnd: 10 },
    { top: 20, bottom: 40, renderedStart: 11, renderedEnd: 21 },
    { top: 40, bottom: 60, renderedStart: 22, renderedEnd: 32 },
  ];

  test('above a line\u2019s middle chooses that line\u2019s top', () => {
    const chosen = chooseDropEdge(blocks, 5);
    expectEqual(chosen.below, false);
    expectEqual(chosen.edge, 0);
    expectEqual(chosen.rendered, 0);
  });

  test('below a line\u2019s middle chooses that line\u2019s bottom', () => {
    const chosen = chooseDropEdge(blocks, 15);
    expectEqual(chosen.below, true);
    expectEqual(chosen.edge, 20);
    expectEqual(chosen.rendered, 10);
  });

  test('stacked lines share an edge, and either offset means that edge', () => {
    // Line 1 ends where line 2 begins, so at y=25 two candidates tie at the
    // same y. Which offset is reported does not matter — `moveImage` snaps both
    // to the same paragraph boundary — but the *edge* must be the shared one,
    // never somewhere inside a line.
    const upper = chooseDropEdge(blocks, 25);
    expectEqual(upper.edge, 20);
    expect(upper.rendered === 10 || upper.rendered === 11, `got ${upper.rendered}`);

    const lower = chooseDropEdge(blocks, 35);
    expectEqual(lower.edge, 40);
    expect(lower.rendered === 21 || lower.rendered === 22, `got ${lower.rendered}`);
  });

  test('every answer is an edge of some line, never a point inside one', () => {
    const edges = new Set(blocks.flatMap((b) => [b.top, b.bottom]));
    for (let y = -30; y <= 90; y += 1) {
      const chosen = chooseDropEdge(blocks, y);
      expect(chosen !== null, `no answer at ${y}`);
      expect(edges.has(chosen.edge), `y ${y} gave a non-edge ${chosen.edge}`);
    }
  });

  test('every answer is a line boundary offset, never a mid-line offset', () => {
    const boundaries = new Set(
      blocks.flatMap((b) => [b.renderedStart, b.renderedEnd])
    );
    for (let y = -30; y <= 90; y += 1) {
      const chosen = chooseDropEdge(blocks, y);
      expect(
        boundaries.has(chosen.rendered),
        `y ${y} gave a mid-line offset ${chosen.rendered}`
      );
    }
  });

  test('far above everything still lands on the first line\u2019s top', () => {
    expectEqual(chooseDropEdge(blocks, -500).rendered, 0);
  });

  test('far below everything still lands on the last line\u2019s bottom', () => {
    expectEqual(chooseDropEdge(blocks, 500).rendered, 32);
  });

  test('zero-height lines are ignored rather than chosen', () => {
    const withEmpty = [
      { top: 0, bottom: 0, renderedStart: 99, renderedEnd: 99 },
      ...blocks,
    ];
    for (let y = -10; y <= 70; y += 5) {
      expect(
        chooseDropEdge(withEmpty, y).rendered !== 99,
        `y ${y} chose a line with no height`
      );
    }
  });

  test('no lines at all is refused rather than guessed at', () => {
    expectEqual(chooseDropEdge([], 10), null);
  });
});
