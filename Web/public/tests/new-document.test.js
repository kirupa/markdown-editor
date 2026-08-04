// A new document starts on a Heading 1 line.
//
// The requirement is a small one — "type the title, press Return, write" —
// but it touches three modules that each have to agree, so it is checked
// across all three rather than in whichever one happens to be convenient:
//
//   document.js      what a new document contains
//   render-model.js  that the caret is understood to be in a heading, which
//                    is what puts "Heading 1" in the paragraph-style control
//   formatting.js    that Return leaves the heading rather than continuing it

import { suite, test, expect, expectEqual } from './harness.js';
import { MarkdownDocumentModel, NEW_DOCUMENT_SOURCE } from '../app/document.js';
import { renderMarkdown } from '../app/core/render-model.js';
import { applyHeading, insertNewline } from '../app/core/formatting.js';
import { makeRange } from '../app/core/range.js';

/** What the paragraph-style control would show for a caret at `location`. */
function headingLevelAt(source, location) {
  let level = 0;
  for (const span of renderMarkdown(source).spans) {
    const start = span.sourceRange.location;
    const end = start + span.sourceRange.length;
    if (location < start || location > end) continue;
    if (span.style.kind === 'heading') level = span.style.level;
  }
  return level;
}

suite('A new document', () => {
  test('starts on an empty Heading 1 line with the caret in it', () => {
    const model = new MarkdownDocumentModel();
    model.reset();

    expectEqual(model.source, '# ');
    expectEqual(model.selection, makeRange(2, 0), 'ready to type the title');
  });

  test('is not unsaved work, so closing it asks nothing', () => {
    const model = new MarkdownDocumentModel();
    model.reset();

    expectEqual(model.isDirty, false);
    expectEqual(model.savedSource, model.source);
  });

  test('is exactly what choosing Heading 1 on an empty document produces', () => {
    // So there is only one idea of "a heading line" in the editor, not two.
    const applied = applyHeading(1, '', makeRange(0, 0));
    expectEqual(applied.text, NEW_DOCUMENT_SOURCE);
  });

  test('reads as Heading 1 at the caret, which is what the style control shows', () => {
    expectEqual(headingLevelAt(NEW_DOCUMENT_SOURCE, NEW_DOCUMENT_SOURCE.length), 1);
  });

  test('is still a Heading 1 once a title has been typed into it', () => {
    const titled = '# Trip notes';
    expectEqual(headingLevelAt(titled, titled.length), 1);
  });
});

suite('Return at the end of a heading', () => {
  test('starts a body paragraph rather than another heading', () => {
    const result = insertNewline('# Trip notes', makeRange(12, 0));

    expectEqual(result.text, '# Trip notes\n');
    expectEqual(result.selection, makeRange(13, 0));
    expectEqual(headingLevelAt(result.text, 13), 0, 'the new line is body text');
  });

  test('leaves the heading behind even from an empty one', () => {
    // The very first Return in a brand new document.
    const result = insertNewline(NEW_DOCUMENT_SOURCE, makeRange(2, 0));
    expectEqual(headingLevelAt(result.text, result.selection.location), 0);
  });

  test('what is typed on the next line is a paragraph, not part of the title', () => {
    const source = '# Trip notes\nWe left on a Tuesday.';
    expectEqual(headingLevelAt(source, source.length), 0);
    expectEqual(headingLevelAt(source, 5), 1, 'while the title above is unchanged');
  });

  test('a list is still continued, so this changed nothing else', () => {
    const result = insertNewline('- first', makeRange(7, 0));
    expectEqual(result.text, '- first\n- ');
  });

  test('Return in the middle of a heading splits it, leaving the tail as body', () => {
    const result = insertNewline('# Trip notes', makeRange(7, 0));
    expectEqual(result.text, '# Trip \nnotes');
    expectEqual(headingLevelAt(result.text, 8), 0);
  });
});

suite('Opening a document does not impose a heading', () => {
  test('a file that starts with a paragraph is left exactly as it is', () => {
    // The rule is about creating a document, not about every document. An
    // opened file must round-trip byte for byte (G-1).
    const opened = 'Just a sentence, with no heading at all.\n';
    expectEqual(headingLevelAt(opened, 0), 0);
    expectEqual(renderMarkdown(opened).text.length > 0, true);
  });

  test('the heading can be removed from a new document like any other', () => {
    const cleared = applyHeading(0, NEW_DOCUMENT_SOURCE, makeRange(2, 0));
    expectEqual(cleared.text, '');
    expect(!cleared.text.startsWith('#'), 'nothing puts it back');
  });
});
