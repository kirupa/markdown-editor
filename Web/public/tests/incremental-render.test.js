// Keeping the render model up to date without rebuilding it.
//
// The model is line-backed so that an edit only reparses the lines it touched.
// That is only worth having if the result is indistinguishable from a full
// parse, so every case here makes the same edit both ways and insists the two
// models agree on the text, on every span, and on every offset mapping.

import { suite, test, expect, expectEqual } from './harness.js';
import { renderMarkdown, MarkdownRenderModel } from '../app/core/render-model.js';
import { insertNewline } from '../app/core/formatting.js';

/** Everything a caller can observe, as one comparable value. */
function shapeOf(model) {
  return {
    text: model.text,
    spans: model.spans.map((span) => ({
      kind: span.style.kind,
      detail:
        span.style.level ??
        span.style.language ??
        span.style.checked ??
        span.style.destination ??
        null,
      rendered: [span.renderedRange.location, span.renderedRange.length],
      source: [span.sourceRange.location, span.sourceRange.length],
      includesMarkup: span.includesMarkup,
      isAtomic: span.isAtomic,
    })),
  };
}

/** Every offset, both ways, including the widened forms selections use. */
function mappingsOf(model) {
  const out = [];
  for (let offset = 0; offset <= model.text.length; offset += 1) {
    out.push(model.sourceRange({ location: offset, length: 0 }).location);
    for (const markup of [false, true]) {
      const range = model.sourceRange(
        { location: offset, length: Math.min(4, model.text.length - offset) },
        markup
      );
      out.push(range.location, range.length);
    }
  }
  for (let offset = 0; offset <= model.source.length; offset += 1) {
    const range = model.renderedRange({
      location: offset,
      length: Math.min(4, model.source.length - offset),
    });
    out.push(range.location, range.length);
  }
  return out.join(',');
}

/** The blocks, derived the way the renderer used to derive them. */
function blocksOfText(text) {
  const out = [];
  let start = 0;
  for (;;) {
    let end = text.indexOf('\n', start);
    if (end === -1) end = text.length;
    out.push([start, end, text.slice(start, end)]);
    if (end === text.length) break;
    start = end + 1;
  }
  return out;
}

function blocksOfModel(model) {
  const out = [];
  for (let index = 0; index < model.blockCount; index += 1) {
    out.push([
      model.blockRenderedStart(index),
      model.blockRenderedEnd(index),
      model.blockText(index),
    ]);
  }
  return out;
}

/**
 * Applies `edits` one at a time and checks the model after each against one
 * parsed from nothing.
 */
function expectIncrementalMatchesFull(start, edits, label) {
  const model = new MarkdownRenderModel(start);
  let source = start;

  for (const [step, edit] of edits.entries()) {
    const next =
      source.slice(0, edit.at) + (edit.insert ?? '') + source.slice(edit.at + (edit.remove ?? 0));
    // Half the time without telling it what changed, because a formatting
    // command and an undo both arrive that way.
    const change =
      step % 2 === 0
        ? {
            previousSource: source,
            range: { location: edit.at, length: edit.remove ?? 0 },
            replacement: edit.insert ?? '',
          }
        : null;

    model.update(next, change);
    source = next;
    const full = renderMarkdown(source);
    const where = `${label}, edit ${step + 1}, source ${JSON.stringify(source.slice(0, 120))}`;

    expectEqual(shapeOf(model), shapeOf(full), `text and spans after ${where}`);
    expectEqual(mappingsOf(model), mappingsOf(full), `offset mappings after ${where}`);
    expectEqual(blocksOfModel(model), blocksOfText(model.text), `blocks after ${where}`);
  }
}

const PARAGRAPHS = '# Title\n\nFirst paragraph with **bold** text.\n\nSecond paragraph.\n';
const FENCED = 'before\n\n```js\nconst a = 1;\nconst b = 2;\n```\n\nafter\n';
const LISTS = '- one\n- two\n- [x] three\n\n1. first\n2. second\n';

suite('Updating the render model in place', () => {
  test('typing in the middle of a paragraph', () => {
    expectIncrementalMatchesFull(
      PARAGRAPHS,
      [
        { at: 30, insert: 'x' },
        { at: 31, insert: 'y' },
        { at: 32, insert: 'z' },
        { at: 30, remove: 3 },
      ],
      'mid-paragraph typing'
    );
  });

  test('opening and closing a fence changes everything below it', () => {
    // The lines under a new fence all render differently, so this is the case
    // where reparsing only the edited line would be wrong.
    expectIncrementalMatchesFull(
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

  test('an unclosed fence swallows the rest of the document', () => {
    expectIncrementalMatchesFull(
      FENCED,
      [
        { at: 45, remove: 4 },
        { at: 45, insert: '```\n' },
        { at: 10, remove: 6 },
      ],
      'unclosed fence'
    );
  });

  test('adding and removing a heading marker', () => {
    expectIncrementalMatchesFull(
      'plain line\nanother line\n',
      [
        { at: 0, insert: '#' },
        { at: 1, insert: ' ' },
        { at: 0, remove: 2 },
        { at: 11, insert: '###### ' },
      ],
      'heading markers'
    );
  });

  test('continuing and breaking a list', () => {
    expectIncrementalMatchesFull(
      LISTS,
      [
        { at: 12, insert: '- four\n' },
        { at: 12, remove: 7 },
        { at: 2, remove: 2 },
        { at: 0, insert: '1. ' },
      ],
      'lists'
    );
  });

  test('a horizontal rule appearing and disappearing', () => {
    expectIncrementalMatchesFull(
      'above\n\nbelow\n',
      [
        { at: 7, insert: '---\n' },
        { at: 9, insert: '-' },
        { at: 7, remove: 5 },
      ],
      'rules'
    );
  });

  test('pasting a large block', () => {
    const pasted = Array.from({ length: 200 }, (_, i) => `- item ${i} with **bold**`).join('\n');
    expectIncrementalMatchesFull(
      PARAGRAPHS,
      [{ at: 9, insert: `${pasted}\n` }, { at: 9, remove: pasted.length + 1 }],
      'a large paste'
    );
  });

  test('deleting a selection that spans many blocks', () => {
    const source = Array.from({ length: 60 }, (_, i) => `## Heading ${i}\n\ntext ${i}\n`).join('');
    expectIncrementalMatchesFull(
      source,
      [
        { at: 30, remove: 400 },
        { at: 0, remove: 25 },
        { at: 5, insert: '\n\n```\n' },
      ],
      'multi-block deletes'
    );
  });

  test('undo and redo, which arrive as a source with no description', () => {
    const model = new MarkdownRenderModel(FENCED);
    const typed = `${FENCED.slice(0, 20)}INSERTED${FENCED.slice(20)}`;
    model.update(typed, null);
    expectEqual(shapeOf(model), shapeOf(renderMarkdown(typed)), 'after the edit');
    // Undo hands back an older source with nothing said about what moved.
    model.update(FENCED, null);
    expectEqual(shapeOf(model), shapeOf(renderMarkdown(FENCED)), 'after undo');
    model.update(typed, null);
    expectEqual(shapeOf(model), shapeOf(renderMarkdown(typed)), 'after redo');
  });

  test('a description that does not match the text is ignored, not believed', () => {
    const model = new MarkdownRenderModel(PARAGRAPHS);
    const next = `${PARAGRAPHS}trailing\n`;
    // A stale description, of the kind a command that forgot to clear one
    // would leave behind.
    model.update(next, {
      previousSource: 'something else entirely',
      range: { location: 0, length: 0 },
      replacement: '!!!',
    });
    expectEqual(shapeOf(model), shapeOf(renderMarkdown(next)));
  });

  test('a very long single line', () => {
    const long = `${'word '.repeat(20000)}**end**`;
    expectIncrementalMatchesFull(
      long,
      [
        { at: 50000, insert: 'X' },
        { at: 50000, remove: 1 },
      ],
      'one long line'
    );
  });

  test('editing an empty document, and emptying one', () => {
    expectIncrementalMatchesFull(
      '',
      [
        { at: 0, insert: '#' },
        { at: 1, insert: ' Title' },
        { at: 0, remove: 7 },
        { at: 0, insert: '\n\n\n' },
        { at: 0, remove: 3 },
      ],
      'empty documents'
    );
  });

  test('a document that is only fence markers', () => {
    expectIncrementalMatchesFull(
      '```\n```\n',
      [
        { at: 4, insert: 'x\n' },
        { at: 4, remove: 2 },
        { at: 0, insert: '\n' },
      ],
      'bare fences'
    );
  });

  test('a whole long document arriving at once', () => {
    // An open, or a revision from another device: every line is new, which is
    // a different path from an edit and one that a long document can break.
    const model = new MarkdownRenderModel('small\n');
    const long = Array.from({ length: 30000 }, (_, i) => `line ${i} of a long document`).join('\n');
    model.update(long);
    expectEqual(model.text, renderMarkdown(long).text, 'the text of a long open');
    expectEqual(model.blockCount, blocksOfText(model.text).length, 'its block count');

    // And again, shrinking, which is the splice in the other direction.
    model.update('small again\n');
    expectEqual(shapeOf(model), shapeOf(renderMarkdown('small again\n')));
  });

  test('the same source twice is not parsed twice', () => {
    const model = new MarkdownRenderModel(PARAGRAPHS);
    const before = model.text;
    expect(model.update(PARAGRAPHS) === model, 'it answers with itself');
    expectEqual(model.text, before);
    expectEqual(model.consumeDirty(), null, 'and reports nothing to redraw');
  });
});

suite('What an update says has to be redrawn', () => {
  /**
   * The blocks outside the reported range are what the DOM is allowed to keep,
   * so they must already be what a full parse would produce.
   */
  function expectDirtyRangeCovers(start, edit) {
    const model = new MarkdownRenderModel(start);
    model.consumeDirty();
    const next =
      start.slice(0, edit.at) + (edit.insert ?? '') + start.slice(edit.at + (edit.remove ?? 0));
    model.update(next);

    const dirty = model.consumeDirty();
    expect(dirty !== null, 'an edit has to report something');
    dirty.blockCount = model.blockCount;

    const full = renderMarkdown(next);
    const fullBlocks = blocksOfModel(full);
    const blocks = blocksOfModel(model);
    expectEqual(blocks, fullBlocks, 'the model itself agrees with a full parse');

    for (let index = blocks.length - dirty.suffix; index < blocks.length; index += 1) {
      expectEqual(
        blocks[index],
        fullBlocks[index],
        `block ${index} is outside the reported range, so it must not have moved`
      );
    }
    for (let index = 0; index < Math.min(dirty.from, blocks.length); index += 1) {
      expectEqual(blocks[index], fullBlocks[index], `block ${index} sits above the edit`);
    }
    return dirty;
  }

  test('typing reports one block, however long the document is', () => {
    for (const lines of [50, 500, 5000]) {
      const source = Array.from({ length: lines }, (_, i) => `paragraph number ${i}`).join('\n\n');
      const dirty = expectDirtyRangeCovers(source, {
        at: Math.floor(source.length / 2),
        insert: 'x',
      });
      const touched = Math.max(0, dirty.blockCount - dirty.suffix - dirty.from);
      expect(
        touched <= 2,
        `typing into a ${lines}-paragraph document reported ${touched} blocks`
      );
    }
  });

  test('opening a fence reports the lines it swallowed', () => {
    const dirty = expectDirtyRangeCovers('a\nb\nc\nd\ne\n', { at: 0, insert: '```\n' });
    expectEqual(dirty.from, 0);
  });

  test('a document open is not an edit and reports everything', () => {
    const model = new MarkdownRenderModel('one\ntwo\n');
    model.consumeDirty();
    model.update('completely different\ntext\nhere\n');
    const dirty = model.consumeDirty();
    expectEqual(dirty.from, 0);
  });
});

suite('Return, which asks the model what it is breaking', () => {
  // Emphasis is matched within a line, so mending a broken run only ever
  // needed that line's spans. Handing the command the model it already has is
  // what keeps Return off the whole document — and it must change nothing.
  const DOCUMENTS = [
    '**bold text** here',
    'a **bold and italic _nested_ run** b',
    '- item with **bold**\n- second',
    '> quoted **bold** line\n> more',
    '```\n**not bold in code**\n```\nafter **bold**',
    '# Heading with `code` in it',
    'plain text with no marks at all',
    '~~struck~~ and <u>underlined</u> together',
    'trailing **unclosed',
  ];

  test('supplying the model changes nothing about where Return breaks', () => {
    for (const source of DOCUMENTS) {
      const model = new MarkdownRenderModel(source);
      for (let caret = 0; caret <= source.length; caret += 1) {
        const selection = { location: caret, length: 0 };
        expectEqual(
          insertNewline(source, selection, model),
          insertNewline(source, selection),
          `breaking ${JSON.stringify(source)} at ${caret}`
        );
      }
    }
  });

  test('a model built on some other text is ignored', () => {
    const source = 'a **bold** run';
    const stale = new MarkdownRenderModel('something else entirely');
    for (let caret = 0; caret <= source.length; caret += 1) {
      const selection = { location: caret, length: 0 };
      expectEqual(
        insertNewline(source, selection, stale),
        insertNewline(source, selection),
        `breaking at ${caret} with a stale model`
      );
    }
  });
});
