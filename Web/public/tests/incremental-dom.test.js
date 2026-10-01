// Redrawing only what an edit disturbed.
//
// The rendered view is an editable projection of the source, so an incremental
// redraw is only allowed if it is indistinguishable from drawing the document
// from nothing. Every case here makes the same edit both ways and compares the
// two trees outright — markup, dataset offsets and all — then checks that the
// incremental one did a bounded amount of work to get there.
//
// They need a real DOM, so they run in the browser page rather than under node.

import { suite, test, expect, expectEqual } from './harness.js';
import {
  renderMarkdown,
  MarkdownRenderModel,
  rejectedChangeCount,
} from '../app/core/render-model.js';
import { renderInto, ensureBlockOffsets } from '../app/ui/renderer.js';
import { EditorSurface } from '../app/ui/editor-surface.js';
import { readPlainText, textOfBlock } from '../app/dom-text.js';

function host() {
  const element = document.createElement('div');
  element.style.position = 'absolute';
  element.style.left = '-10000px';
  document.body.append(element);
  return element;
}

const IMAGE = (destination) => `about:blank#${destination}`;

/**
 * Applies `edits` to `start`, redrawing incrementally, and compares the result
 * against a surface drawn from nothing after every one.
 */
function expectRedrawMatchesFullRender(start, edits, label) {
  const incremental = host();
  const fresh = host();
  try {
    const model = new MarkdownRenderModel(start);
    renderInto(incremental, model, IMAGE);
    let source = start;
    let worst = 0;

    for (const [step, edit] of edits.entries()) {
      const next =
        source.slice(0, edit.at) +
        (edit.insert ?? '') +
        source.slice(edit.at + (edit.remove ?? 0));
      model.update(next, {
        previousSource: source,
        range: { location: edit.at, length: edit.remove ?? 0 },
        replacement: edit.insert ?? '',
      });
      source = next;

      const work = renderInto(incremental, model, IMAGE);
      worst = Math.max(worst, work.replaced);
      renderInto(fresh, renderMarkdown(source), IMAGE);

      const where = `${label}, edit ${step + 1}`;
      // Offsets below an edit are corrected when something reads them, so a
      // comparison of the markup has to ask for them first.
      ensureBlockOffsets(incremental);
      expectEqual(incremental.innerHTML, fresh.innerHTML, `the tree after ${where}`);
      expectEqual(readPlainText(incremental), model.text, `the text after ${where}`);
    }
    return worst;
  } finally {
    incremental.remove();
    fresh.remove();
  }
}

const PARAGRAPHS = '# Title\n\nFirst paragraph with **bold** text.\n\nSecond paragraph.\n';
const FENCED = 'before\n\n```js\nconst a = 1;\nconst b = 2;\n```\n\nafter\n';

suite('Redrawing only what changed', () => {
  test('typing in the middle of a paragraph', () => {
    expectRedrawMatchesFullRender(
      PARAGRAPHS,
      [
        { at: 30, insert: 'x' },
        { at: 31, insert: 'y' },
        { at: 30, remove: 2 },
      ],
      'mid-paragraph typing'
    );
  });

  test('opening and closing a fence', () => {
    expectRedrawMatchesFullRender(
      'alpha\nbeta\ngamma\ndelta\n',
      [
        { at: 0, insert: '```\n' },
        { at: 0, remove: 4 },
        { at: 6, insert: '```js\n' },
        { at: 22, insert: '```\n' },
      ],
      'fences'
    );
  });

  test('a fenced run keeps its rounded ends as it grows and shrinks', () => {
    // The first and last lines of a run are the only ones with rounded
    // corners (Y-5), and either can stop being either — which is why a redraw
    // reaches one block beyond what the model reports.
    expectRedrawMatchesFullRender(
      FENCED,
      [
        { at: 41, insert: 'const c = 3;\n' },
        { at: 41, remove: 13 },
        { at: 54, remove: 4 },
        { at: 54, insert: '```\n' },
      ],
      'fence ends'
    );
  });

  test('adding and removing a heading marker', () => {
    expectRedrawMatchesFullRender(
      'plain line\nanother line\n',
      [
        { at: 0, insert: '#' },
        { at: 1, insert: ' ' },
        { at: 0, remove: 2 },
      ],
      'heading markers'
    );
  });

  test('continuing and breaking a list', () => {
    expectRedrawMatchesFullRender(
      '- one\n- two\n- [x] three\n',
      [
        { at: 12, insert: '- four\n' },
        { at: 12, remove: 7 },
        { at: 2, remove: 2 },
      ],
      'lists'
    );
  });

  test('pictures, whose blocks reach into the margins', () => {
    expectRedrawMatchesFullRender(
      'Before.\n\n![a](a.png)\n\n<img src="b.png" alt="b" width="300">\n\nAfter.\n',
      [
        { at: 8, insert: 'x' },
        { at: 8, remove: 1 },
        { at: 21, insert: 'words ' },
        { at: 21, remove: 6 },
      ],
      'pictures'
    );
  });

  test('pasting a large block, then deleting it again', () => {
    const pasted = Array.from({ length: 120 }, (_, i) => `- item ${i}`).join('\n');
    expectRedrawMatchesFullRender(
      PARAGRAPHS,
      [
        { at: 9, insert: `${pasted}\n` },
        { at: 9, remove: pasted.length + 1 },
      ],
      'a large paste'
    );
  });

  test('deleting a selection spanning many blocks', () => {
    const source = Array.from({ length: 40 }, (_, i) => `## Heading ${i}\n\ntext ${i}\n`).join('');
    expectRedrawMatchesFullRender(
      source,
      [
        { at: 30, remove: 300 },
        { at: 0, remove: 25 },
      ],
      'multi-block deletes'
    );
  });

  test('emptying a document and filling it again', () => {
    expectRedrawMatchesFullRender(
      PARAGRAPHS,
      [
        { at: 0, remove: PARAGRAPHS.length },
        { at: 0, insert: '# New\n\nBody\n' },
        { at: 0, insert: '\n' },
      ],
      'emptying'
    );
  });

  test('a very long single line', () => {
    expectRedrawMatchesFullRender(
      `${'word '.repeat(4000)}**end**`,
      [
        { at: 10000, insert: 'X' },
        { at: 10000, remove: 1 },
      ],
      'one long line'
    );
  });
});

suite('How much a redraw costs', () => {
  /** Blocks replaced by a single-character edit in the middle. */
  function blocksReplacedByOneKeystroke(paragraphs) {
    const source = Array.from(
      { length: paragraphs },
      (_, i) => `Paragraph ${i} with **bold** and a \`code\` run in it.`
    ).join('\n\n');

    const element = host();
    try {
      const model = new MarkdownRenderModel(source);
      renderInto(element, model, IMAGE);
      const at = Math.floor(source.length / 2);
      const next = `${source.slice(0, at)}x${source.slice(at)}`;
      model.update(next, {
        previousSource: source,
        range: { location: at, length: 0 },
        replacement: 'x',
      });
      const work = renderInto(element, model, IMAGE);
      expectEqual(readPlainText(element), model.text, 'the text still matches the model');
      return work;
    } finally {
      element.remove();
    }
  }

  test('a keystroke costs the same in a long document as in a short one', () => {
    // Counted rather than timed: a clock in a test suite measures the machine
    // it runs on. What matters is that the work does not grow with the
    // document, which is what these numbers say.
    const small = blocksReplacedByOneKeystroke(20);
    const large = blocksReplacedByOneKeystroke(2000);
    expect(
      small.replaced <= 3,
      `a keystroke in a short document replaced ${small.replaced} blocks`
    );
    expectEqual(
      large.replaced,
      small.replaced,
      'a hundredfold longer document must cost the same'
    );
    expect(large.built <= 3, `it built ${large.built} blocks`);
  });

  test('a first draw builds everything, because there is nothing to keep', () => {
    const element = host();
    try {
      const model = new MarkdownRenderModel('one\n\ntwo\n\nthree\n');
      const work = renderInto(element, model, IMAGE);
      expectEqual(work.built, model.blockCount);
    } finally {
      element.remove();
    }
  });

  test('an unchanged neighbour keeps the element it already had', () => {
    const element = host();
    try {
      const model = new MarkdownRenderModel('one\n\ntwo\n\nthree\n');
      renderInto(element, model, IMAGE);
      const untouched = element.childNodes[4];
      model.update('one\n\ntwoX\n\nthree\n', {
        previousSource: 'one\n\ntwo\n\nthree\n',
        range: { location: 8, length: 0 },
        replacement: 'X',
      });
      renderInto(element, model, IMAGE);
      expect(element.childNodes[4] === untouched, 'the block below the edit is the same element');
    } finally {
      element.remove();
    }
  });
});

suite('Offsets a redraw leaves behind', () => {
  test('every block says where it really is once something asks', () => {
    const element = host();
    try {
      const source = Array.from({ length: 200 }, (_, i) => `line ${i}`).join('\n');
      const model = new MarkdownRenderModel(source);
      renderInto(element, model, IMAGE);
      model.update(`inserted\n${source}`, {
        previousSource: source,
        range: { location: 0, length: 0 },
        replacement: 'inserted\n',
      });
      renderInto(element, model, IMAGE);

      ensureBlockOffsets(element);
      for (let index = 0; index < model.blockCount; index += 1) {
        const block = element.childNodes[index];
        expectEqual(
          Number(block.dataset.renderedStart),
          model.blockRenderedStart(index),
          `block ${index} start`
        );
        expectEqual(
          Number(block.dataset.renderedEnd),
          model.blockRenderedEnd(index),
          `block ${index} end`
        );
      }
    } finally {
      element.remove();
    }
  });

  test('a picture below an edit still points at its own Markdown', () => {
    const element = host();
    try {
      const source = 'top\n\n![a](a.png)\n\nbottom\n';
      const model = new MarkdownRenderModel(source);
      renderInto(element, model, IMAGE);
      model.update(`xyz\n${source}`, {
        previousSource: source,
        range: { location: 0, length: 0 },
        replacement: 'xyz\n',
      });
      renderInto(element, model, IMAGE);

      ensureBlockOffsets(element);
      const picture = element.querySelector('.me-image');
      const location = Number(picture.dataset.sourceLocation);
      const length = Number(picture.dataset.sourceLength);
      expectEqual(`xyz\n${source}`.slice(location, location + length), '![a](a.png)');
    } finally {
      element.remove();
    }
  });
});

suite('Reading an edit out of the surface', () => {
  /**
   * A surface over a render model, with a document stub standing in for the
   * real one so this stays a test of the reading and not of the whole app.
   */
  function surfaceOver(source) {
    const element = host();
    element.id = `surface-${Math.random().toString(36).slice(2)}`;
    const model = new MarkdownRenderModel(source);
    const edits = [];
    const stub = {
      source,
      selection: { location: 0, length: 0 },
      edit(next, selection, options) {
        edits.push({ next, selection, options });
      },
      undo() {},
      redo() {},
    };
    const projection = {
      render: (text) => renderInto(element, model.update(text), IMAGE),
      textFor: (text) => model.update(text).text,
      toSource: (text, range) => model.update(text).sourceRange(range),
      toSurface: (text, range) => model.update(text).renderedRange(range),
      layoutFor: (text) => model.update(text),
    };
    const surface = new EditorSurface(element, projection, stub);
    surface.sync(source, stub.selection, { force: true });
    return { element, surface, model, edits, stub };
  }

  /** Puts the caret at the end of a block, the way a browser would. */
  function caretAtEndOf(block) {
    const range = document.createRange();
    range.selectNodeContents(block);
    range.collapse(false);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  /**
   * Both readings of the same edit have to leave the surface saying the same
   * thing. They need not agree on where to put it: a character typed next to
   * an identical one can honestly be described in more than one way. What the
   * local reading must never do is claim more than it has to, which is what
   * makes an untouched paragraph get rewritten.
   */
  function expectBothReadingsAgree(source, mutate, label) {
    const { element, surface, model, edits } = surfaceOver(source);
    try {
      element.focus();
      mutate(element);
      surface.noteSelectedBlocks();
      const local = surface.changedRegion();
      const whole = surface.changedDocument();
      expect(whole !== null, `${label}: the whole-surface reading found a change`);
      if (local === null) return; // it declined, which is always allowed

      const apply = (change) =>
        model.text.slice(0, change.range.location) +
        change.replacement +
        model.text.slice(change.range.location + change.range.length);
      expectEqual(apply(local), apply(whole), `${label}: the two readings say the same thing`);

      const removed = model.text.slice(
        local.range.location,
        local.range.location + local.range.length
      );
      expect(
        removed.length === 0 ||
          local.replacement.length === 0 ||
          (removed[0] !== local.replacement[0] &&
            removed[removed.length - 1] !== local.replacement[local.replacement.length - 1]),
        `${label}: the local reading rewrote text it did not have to`
      );
      expectEqual(edits.length, 0, 'reading an edit does not apply one');
    } finally {
      element.remove();
    }
  }

  test('a character typed into a paragraph', () => {
    expectBothReadingsAgree(
      PARAGRAPHS,
      (element) => {
        const block = element.childNodes[2];
        block.firstChild.nodeValue = `${block.firstChild.nodeValue}!`;
        caretAtEndOf(block);
      },
      'typing'
    );
  });

  test('a character typed into the last block', () => {
    expectBothReadingsAgree(
      'one\n\ntwo\n\nthree',
      (element) => {
        const block = element.childNodes[element.childNodes.length - 1];
        block.firstChild.nodeValue = `${block.firstChild.nodeValue}X`;
        caretAtEndOf(block);
      },
      'typing at the end'
    );
  });

  test('a block merged into the one above it', () => {
    expectBothReadingsAgree(
      'one\ntwo\nthree\n',
      (element) => {
        // What a backspace at the start of the second line leaves behind.
        const first = element.childNodes[0];
        const second = element.childNodes[1];
        first.append(...second.childNodes);
        second.remove();
        caretAtEndOf(first);
      },
      'a merge'
    );
  });

  test('several blocks removed at once', () => {
    expectBothReadingsAgree(
      'one\ntwo\nthree\nfour\nfive\n',
      (element) => {
        const first = element.childNodes[0];
        for (let index = 0; index < 3; index += 1) element.childNodes[1].remove();
        first.firstChild.nodeValue = 'o';
        caretAtEndOf(first);
      },
      'a multi-block delete'
    );
  });

  test('text pasted as several blocks', () => {
    expectBothReadingsAgree(
      'one\ntwo\n',
      (element) => {
        const first = element.childNodes[0];
        for (const line of ['alpha', 'beta']) {
          const block = document.createElement('div');
          block.className = 'me-block';
          block.append(document.createTextNode(line));
          first.after(block);
        }
        caretAtEndOf(element.childNodes[2]);
      },
      'a paste'
    );
  });

  test('a surface with no layout falls back to reading everything', () => {
    const element = host();
    try {
      const model = new MarkdownRenderModel('one\ntwo\n');
      const stub = { source: 'one\ntwo\n', selection: { location: 0, length: 0 }, edit() {} };
      const surface = new EditorSurface(
        element,
        {
          render: (text) => renderInto(element, model.update(text), IMAGE),
          textFor: (text) => model.update(text).text,
          toSource: (text, range) => model.update(text).sourceRange(range),
          toSurface: (text, range) => model.update(text).renderedRange(range),
        },
        stub
      );
      surface.sync('one\ntwo\n', stub.selection, { force: true });
      expectEqual(surface.changedRegion(), null, 'with no layout it declines');
      element.childNodes[0].firstChild.nodeValue = 'ONE';
      const whole = surface.changedDocument();
      expectEqual(whole.replacement, 'ONE');
      expect(textOfBlock(element.childNodes[0]) === 'ONE', 'the block really did change');
    } finally {
      element.remove();
    }
  });
});

suite('The description an edit hands the model', () => {
  /**
   * The surface, the document and the model wired the way `main.js` wires
   * them: an edit carries what it replaced, the document holds it, and the
   * model is offered it on the next draw.
   *
   * What this is really testing is that the description the surface produces
   * is one the model can actually use. It is only ever a shortcut — a wrong
   * one still renders correctly — so the only symptom of getting it wrong is
   * that every keystroke quietly reads the whole document again, which is the
   * thing this whole change exists to stop.
   */
  function editorOver(source) {
    const element = host();
    const model = new MarkdownRenderModel(source);
    const document_ = {
      source,
      selection: { location: 0, length: 0 },
      lastChange: null,
      edit(next, selection, { change = null } = {}) {
        this.lastChange = change;
        this.source = next;
        this.selection = selection;
        surface.sync(next, selection, { force: true });
      },
      undo() {},
      redo() {},
    };
    const layoutFor = (text) => model.update(text, document_.lastChange);
    const surface = new EditorSurface(
      element,
      {
        render: (text) => renderInto(element, layoutFor(text), IMAGE),
        textFor: (text) => layoutFor(text).text,
        toSource: (text, range) => layoutFor(text).sourceRange(range),
        toSurface: (text, range) => layoutFor(text).renderedRange(range),
        layoutFor,
      },
      document_
    );
    surface.sync(source, document_.selection, { force: true });
    return { element, surface, model, document: document_ };
  }

  test('typing hands over a description the model can use', () => {
    const { element, surface, document: document_ } = editorOver(
      '# Title\n\nFirst paragraph.\n\nSecond paragraph.\n'
    );
    try {
      element.focus();
      const before = rejectedChangeCount();

      for (const letter of 'abcde') {
        const block = element.childNodes[2];
        block.firstChild.nodeValue = `${block.firstChild.nodeValue}${letter}`;
        const range = window.document.createRange();
        range.selectNodeContents(block);
        range.collapse(false);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        surface.noteSelectedBlocks();
        surface.handleInput();
      }

      expect(document_.source.includes('abcde'), `the edits landed: ${document_.source}`);
      expectEqual(
        rejectedChangeCount(),
        before,
        'every keystroke must hand over a description the model can use'
      );
    } finally {
      element.remove();
    }
  });

  test('Return hands over no description rather than a wrong one', () => {
    // The command rewrites the source through the formatting layer, so the
    // surface has nothing honest to say about what it replaced. Saying
    // nothing costs a full diff once; saying the wrong thing would be a
    // rejected description on every Return, which is the same cost plus a
    // warning.
    const { element, surface, document: document_ } = editorOver('- item\n');
    try {
      element.focus();
      const before = rejectedChangeCount();
      surface.handleBeforeInput({
        inputType: 'insertParagraph',
        preventDefault() {},
      });
      expect(document_.source.length > '- item\n'.length, 'Return inserted something');
      expectEqual(rejectedChangeCount(), before, 'and told the model nothing it had to reject');
    } finally {
      element.remove();
    }
  });
});
