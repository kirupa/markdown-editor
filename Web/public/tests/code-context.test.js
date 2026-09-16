// Formatting where Markdown is inert — the web half of
// `Shared/Tests/MarkdownEditorCoreTests/MarkdownCodeContextTests.swift`.
//
// The bug these pin down: the caret was inside a fenced code block, bold was
// applied, and `**bold text**` went into the document as eleven characters of
// the writer's code. The reading view was right to show the markers, because
// inside a fence that is what they are.
//
// The block quote half of the same report is here too, as the opposite
// assertion: a quote is prose, bold in a quote is ordinary Markdown, and these
// fail if a future "fix" starts refusing there.

import { suite, test, expect } from './harness.js';
import {
  InlineStyle,
  toggleInline,
  insertLink,
  isInlineStyleAvailable,
  isLinkAvailable,
} from '../app/core/formatting.js';
import { CodeContextKind, codeContextIn, isCodeContext } from '../app/core/code-context.js';
import { renderMarkdown } from '../app/core/render-model.js';
import { makeRange } from '../app/core/range.js';

const STYLES = Object.values(InlineStyle);

function at(location, length = 0) {
  return makeRange(location, length);
}

function rangeOf(text, needle) {
  const location = text.indexOf(needle);
  return makeRange(location, needle.length);
}

suite('Formatting inside code and quotes', () => {
  test('the caret inside a fence reports the block, fences and all', () => {
    const text = 'para\n\n```swift\nlet x = 1\n```\n\nafter\n';
    const block = makeRange(6, 23);
    expect(text.slice(6, 29) === '```swift\nlet x = 1\n```\n', 'the block is not where expected');

    for (let caret = block.location; caret < block.location + block.length; caret += 1) {
      const context = codeContextIn(at(caret), text);
      expect(context.kind === CodeContextKind.codeBlock, `caret ${caret} is not in the block`);
    }
    expect(codeContextIn(at(5), text).kind === CodeContextKind.prose, 'before the fence is code');
    expect(codeContextIn(at(29), text).kind === CodeContextKind.prose, 'after the fence is code');
  });

  test('every inline style refuses inside a fenced code block', () => {
    // The reported document, before the markers went in.
    const text = '# \n```\nsdf\n\nnsd\n```\n';
    const caret = at(11);
    for (const style of STYLES) {
      expect(
        !isInlineStyleAvailable(style, codeContextIn(caret, text)),
        `${style} is offered inside a fence`
      );
      const result = toggleInline(style, text, caret);
      expect(result.text === text, `${style} wrote into a code block`);
      expect(
        result.selection.location === 11 && result.selection.length === 0,
        `${style} moved the caret`
      );
    }
  });

  test('a selected word inside a fence is not bolded', () => {
    const text = '```\nlet total = 1\n```\n';
    const selection = rangeOf(text, 'total');
    expect(toggleInline(InlineStyle.bold, text, selection).text === text, 'bold wrote into code');
  });

  test('a fence line itself refuses, because writing there breaks the fence', () => {
    const text = '```swift\nlet x = 1\n```\n';
    for (const caret of [0, 4, 19, 21]) {
      expect(
        toggleInline(InlineStyle.bold, text, at(caret)).text === text,
        `caret ${caret} wrote into a fence line`
      );
    }
  });

  test('an unterminated fence is still a code block to the end of the file', () => {
    const text = 'intro\n\n```\nlet x = 1\n';
    expect(isCodeContext(codeContextIn(at(15), text)), 'an unclosed fence is not code');
    expect(toggleInline(InlineStyle.italic, text, at(15)).text === text, 'italic wrote into it');
  });

  test('a link is refused inside a fence as well', () => {
    const text = '```\nlet x = 1\n```\n';
    const selection = rangeOf(text, 'let x');
    expect(!isLinkAvailable(codeContextIn(selection, text)), 'a link is offered inside a fence');
    expect(
      insertLink('https://example.com', text, selection).text === text,
      'a link was written into code'
    );
  });

  test('a quote written inside a fence is code, not a quote', () => {
    const text = '```\n> quoted inside the fence\n```\n';
    const selection = rangeOf(text, 'quoted');
    expect(isCodeContext(codeContextIn(selection, text)), 'a quote line in a fence is not code');
    expect(toggleInline(InlineStyle.bold, text, selection).text === text, 'bold wrote into it');
    expect(
      renderMarkdown(text).text.includes('> quoted inside the fence'),
      'the renderer hid a quote marker that is really code'
    );
  });

  test('a fence written inside a quote is a quote, not a fence', () => {
    // "> ```" is not a fence: a fence has to start its own line.
    const text = '> ```\n> still quoted\n';
    const selection = rangeOf(text, 'still');
    expect(codeContextIn(selection, text).kind === CodeContextKind.prose, 'a quote became code');
    expect(
      toggleInline(InlineStyle.bold, text, selection).text === '> ```\n> **still** quoted\n',
      'bold was refused in a quote'
    );
  });

  test('emphasis refuses between a code span backticks', () => {
    const text = 'Call `reload(now:)` to refresh.\n';
    const selection = rangeOf(text, 'reload');
    const context = codeContextIn(selection, text);
    expect(context.kind === CodeContextKind.inlineCodeSpan, 'a code span was not recognised');
    expect(
      context.sourceRange.location === 5 && context.sourceRange.length === 14,
      'the span is not where expected'
    );
    for (const style of [InlineStyle.bold, InlineStyle.italic, InlineStyle.underline, InlineStyle.strikethrough]) {
      expect(!isInlineStyleAvailable(style, context), `${style} is offered inside a code span`);
      expect(toggleInline(style, text, selection).text === text, `${style} wrote into a code span`);
    }
    expect(!isLinkAvailable(context), 'a link is offered inside a code span');
  });

  test('a selection holding a whole code span may still be emphasised', () => {
    const text = 'Call `reload()` now.\n';
    const selection = rangeOf(text, 'Call `reload()` now');
    expect(codeContextIn(selection, text).kind === CodeContextKind.prose, 'prose read as code');
    expect(
      toggleInline(InlineStyle.bold, text, selection).text === '**Call `reload()` now**.\n',
      'bold around a code span was refused'
    );
  });

  test('a caret at either end of a code span is in the prose beside it', () => {
    const text = 'a `code` b\n';
    for (const caret of [2, 8]) {
      expect(
        codeContextIn(at(caret), text).kind === CodeContextKind.prose,
        `caret ${caret} should be outside the span`
      );
    }
    for (let caret = 3; caret <= 7; caret += 1) {
      expect(isCodeContext(codeContextIn(at(caret), text)), `caret ${caret} should be inside`);
    }
  });

  test('inline code stays available inside a span, and takes the span off', () => {
    const text = 'a `code` b\n';
    const caret = at(5);
    expect(
      isInlineStyleAvailable(InlineStyle.inlineCode, codeContextIn(caret, text)),
      'inline code cannot be undone from the caret'
    );
    const result = toggleInline(InlineStyle.inlineCode, text, caret);
    expect(result.text === 'a code b\n', `got ${JSON.stringify(result.text)}`);
    expect(result.selection.location === 4 && result.selection.length === 0, 'the caret jumped');
  });

  test('toggling code off from a caret undoes a padded, doubled delimiter', () => {
    const text = 'a `` foo` `` b\n';
    const result = toggleInline(InlineStyle.inlineCode, text, at(6));
    expect(result.text === 'a foo` b\n', `got ${JSON.stringify(result.text)}`);
    expect(result.selection.location === 3, 'the caret did not follow the content');
  });

  test('a selection crossing a backtick run takes the span off rather than nesting one', () => {
    const text = 'a `code` b\n';
    const result = toggleInline(InlineStyle.inlineCode, text, makeRange(2, 4));
    expect(result.text === 'a code b\n', `got ${JSON.stringify(result.text)}`);
    expect(renderMarkdown(result.text).text === 'a code b\n', 'markers survived on screen');
  });

  test('selecting a code span contents still toggles it off as it always did', () => {
    const text = 'Use `value` here';
    const result = toggleInline(InlineStyle.inlineCode, text, rangeOf(text, 'value'));
    expect(result.text === 'Use value here', `got ${JSON.stringify(result.text)}`);
    expect(result.selection.location === 4 && result.selection.length === 5, 'the selection moved');
  });

  test('bold inside a block quote is written, and its markers are hidden', () => {
    const text = '> quoted line\n';
    const selection = rangeOf(text, 'quoted');
    expect(codeContextIn(selection, text).kind === CodeContextKind.prose, 'a quote read as code');

    const result = toggleInline(InlineStyle.bold, text, selection);
    expect(result.text === '> **quoted** line\n', `got ${JSON.stringify(result.text)}`);

    // The point of the report: the syntax must not come back on screen.
    const model = renderMarkdown(result.text);
    expect(model.text === 'quoted line\n', `rendered ${JSON.stringify(model.text)}`);
    expect(
      model.spans.some(
        (span) =>
          span.style.kind === 'bold' &&
          span.renderedRange.location === 0 &&
          span.renderedRange.length === 6
      ),
      'the bold span is missing inside the quote'
    );
    expect(model.spans.some((span) => span.style.kind === 'quote'), 'the quote span is missing');
  });

  test('every inline style and a link work in a quote, markers hidden', () => {
    const text = '> quoted line\n';
    const selection = rangeOf(text, 'quoted');
    for (const style of STYLES) {
      expect(
        isInlineStyleAvailable(style, codeContextIn(selection, text)),
        `${style} is refused in a quote`
      );
      const result = toggleInline(style, text, selection);
      expect(result.text !== text, `${style} did nothing in a quote`);
      expect(
        renderMarkdown(result.text).text === 'quoted line\n',
        `${style} left its markers on screen in a quote`
      );
    }
    expect(isLinkAvailable(codeContextIn(selection, text)), 'a link is refused in a quote');
  });

  test('a nested quote is prose too', () => {
    const text = '> outer\n>> nested quote\n';
    const selection = rangeOf(text, 'nested');
    expect(codeContextIn(selection, text).kind === CodeContextKind.prose, 'a nested quote is code');
    expect(
      toggleInline(InlineStyle.bold, text, selection).text === '> outer\n>> **nested** quote\n',
      'bold was refused in a nested quote'
    );
  });

  test('a code span inside a quote is still code', () => {
    const text = '> call `reload()` first\n';
    const selection = rangeOf(text, 'reload');
    expect(isCodeContext(codeContextIn(selection, text)), 'a code span in a quote is not code');
    expect(toggleInline(InlineStyle.bold, text, selection).text === text, 'bold wrote into it');
  });

  test('a four-space indented line is a paragraph, and formats like one', () => {
    // This renderer does not implement indented code blocks: the line is drawn
    // as ordinary prose, emphasis on it is drawn as emphasis, and so refusing
    // to format it would stop a command that visibly works. If indented code
    // is ever added to the render model, this test should flip, not be deleted.
    const text = 'para\n\n    let x = 1\n';
    const selection = rangeOf(text, 'let x');
    expect(renderMarkdown(text).spans.length === 0, 'the renderer now models indented code');
    expect(codeContextIn(selection, text).kind === CodeContextKind.prose, 'indented code is code');

    const result = toggleInline(InlineStyle.bold, text, selection);
    expect(result.text === 'para\n\n    **let x** = 1\n', `got ${JSON.stringify(result.text)}`);
    expect(renderMarkdown(result.text).text === 'para\n\n    let x = 1\n', 'markers are visible');
  });
});
