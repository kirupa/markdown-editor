// DOM-dependent tests.
//
// The invariant these protect is the one everything else rests on: the text a
// surface shows must equal, character for character, the text the model says
// it should show. If that ever drifts, every offset the ported core computes
// lands in the wrong place.
//
// They need a real DOM, so they run in the browser page rather than under node.

import { suite, test, expect, expectEqual } from './harness.js';
import { renderMarkdown } from '../app/core/render-model.js';
import { renderInto } from '../app/ui/renderer.js';
import { renderSourceInto } from '../app/ui/source-renderer.js';
import {
  readPlainText,
  offsetForPosition,
  positionForOffset,
} from '../app/dom-text.js';
import { rememberedMode, preferredMode, LOCAL, CLOUD } from '../app/storage.js';

function host() {
  const element = document.createElement('div');
  element.style.position = 'absolute';
  element.style.left = '-10000px';
  document.body.append(element);
  return element;
}

const DOCUMENTS = [
  '',
  'plain text',
  '# Heading\n\nBody paragraph.\n',
  '- one\n- two\n- three\n',
  '1. first\n2. second\n',
  '- [x] done\n- [ ] pending\n',
  '> quoted line\n> second line\n',
  '```swift\nlet a = 1\nlet b = 2\n```\n',
  'Some **bold**, *italic*, ~~struck~~, and `code`.\n',
  '[a link](https://example.com/) plus ![alt](pic.png)\n',
  '---\n\nafter the rule\n',
  '###### deep heading\n\ntrailing\n',
  'line with a \\* escaped star\n',
  'Ünïcödé and emoji 🎉 in one line\n',
  '# H\n\n> quote with **bold**\n\n```\nraw\n```\n\n- list\n',
  'text\n\n\n\nmany blank lines\n',
  'trailing newline\n',
  'no trailing newline',
];

suite('Rendered DOM', () => {
  test('reproduces the model text exactly', () => {
    const element = host();
    for (const markdown of DOCUMENTS) {
      const model = renderMarkdown(markdown);
      renderInto(element, model);
      expectEqual(
        readPlainText(element),
        model.text,
        `rendered DOM text differs for ${JSON.stringify(markdown)}`
      );
    }
    element.remove();
  });

  test('round-trips every offset through the DOM', () => {
    const element = host();
    for (const markdown of DOCUMENTS) {
      const model = renderMarkdown(markdown);
      renderInto(element, model);
      for (let offset = 0; offset <= model.text.length; offset += 1) {
        const position = positionForOffset(element, offset);
        const back = offsetForPosition(element, position.node, position.offset);
        expectEqual(
          back,
          offset,
          `offset ${offset} did not survive the round trip for ${JSON.stringify(markdown)}`
        );
      }
    }
    element.remove();
  });

  test('marks the ends of a fenced block exactly once', () => {
    const element = host();
    renderInto(element, renderMarkdown('before\n\n```\na\nb\nc\n```\n\nafter\n'));
    expectEqual(element.querySelectorAll('.me-code-block--first').length, 1);
    expectEqual(element.querySelectorAll('.me-code-block--last').length, 1);
    expectEqual(element.querySelectorAll('.me-code-block').length, 3);
    element.remove();
  });

  test('keeps two fences apart', () => {
    const element = host();
    renderInto(element, renderMarkdown('```\na\n```\n\ntext\n\n```\nb\n```\n'));
    expectEqual(element.querySelectorAll('.me-code-block--first').length, 2);
    expectEqual(element.querySelectorAll('.me-code-block--last').length, 2);
    element.remove();
  });

  test('gives an image an atomic, non-editable node', () => {
    const element = host();
    renderInto(element, renderMarkdown('![alt](pic.png)\n'), () => 'pic.png');
    const image = element.querySelector('.me-image');
    expect(image !== null, 'expected an image node');
    expectEqual(image.contentEditable, 'false');
    expectEqual(image.dataset.destination, 'pic.png');
    element.remove();
  });

  test('shows a placeholder when the image cannot be resolved', () => {
    const element = host();
    renderInto(element, renderMarkdown('![alt](missing.png)\n'), () => null);
    expect(element.querySelector('.me-image--broken') !== null);
    element.remove();
  });

  test('applies heading classes per level', () => {
    const element = host();
    renderInto(element, renderMarkdown('# a\n\n## b\n\n### c\n\n#### d\n\n##### e\n\n###### f\n'));
    for (let level = 1; level <= 6; level += 1) {
      expectEqual(
        element.querySelectorAll(`.me-h${level}`).length,
        1,
        `expected one h${level}`
      );
    }
    element.remove();
  });
});

suite('Source DOM', () => {
  test('reproduces the source exactly', () => {
    const element = host();
    for (const markdown of DOCUMENTS) {
      renderSourceInto(element, markdown, renderMarkdown(markdown));
      expectEqual(
        readPlainText(element),
        markdown,
        `source DOM text differs for ${JSON.stringify(markdown)}`
      );
    }
    element.remove();
  });

  test('round-trips every offset through the DOM', () => {
    const element = host();
    for (const markdown of DOCUMENTS) {
      renderSourceInto(element, markdown, renderMarkdown(markdown));
      for (let offset = 0; offset <= markdown.length; offset += 1) {
        const position = positionForOffset(element, offset);
        expectEqual(
          offsetForPosition(element, position.node, position.offset),
          offset,
          `offset ${offset} did not survive for ${JSON.stringify(markdown)}`
        );
      }
    }
    element.remove();
  });

  test('sizes headings and fenced code but styles nothing else', () => {
    const element = host();
    renderSourceInto(
      element,
      '## Title\n\n> quote\n\n```swift\ncode\n```\n',
      renderMarkdown('## Title\n\n> quote\n\n```swift\ncode\n```\n')
    );
    expectEqual(element.querySelectorAll('.me-src-h2').length, 1);
    // The fence markers count as code too, matching MarkdownSourceStyler.
    expectEqual(element.querySelectorAll('.me-src-code').length, 3);
    expectEqual(element.querySelectorAll('[class*="me-src-quote"]').length, 0);
    element.remove();
  });
});

/**
 * Where a first-time visitor's documents go (WR-1).
 *
 * `rememberedMode()` reads `window.localStorage`, so it is only testable where
 * there is a real one — under node the key is unreadable and every assertion
 * about it passes trivially. It is tested here because the distinction it
 * draws carries the whole fallback rule: collapse "has not chosen" onto
 * "chose the server" and the editor stops asking, and quietly starts everyone
 * in a workspace anyone reaching the page can edit.
 */
suite('Remembered storage mode', () => {
  const KEY = 'markdown-editor.storageMode';
  const withStored = (value, body) => {
    const previous = localStorage.getItem(KEY);
    try {
      if (value === null) localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, value);
      body();
    } finally {
      if (previous === null) localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, previous);
    }
  };

  test('a visitor who has never chosen is distinguishable from one who chose local', () => {
    withStored(null, () => expectEqual(rememberedMode(), null));
    withStored(LOCAL, () => expectEqual(rememberedMode(), LOCAL));
    withStored(CLOUD, () => expectEqual(rememberedMode(), CLOUD));
  });

  test('an unrecognised value counts as never having chosen', () => {
    withStored('something-else', () => expectEqual(rememberedMode(), null));
    withStored('', () => expectEqual(rememberedMode(), null));
  });

  test('preferredMode still answers local for a visitor who has not chosen', () => {
    withStored(null, () => expectEqual(preferredMode(), LOCAL));
    withStored(CLOUD, () => expectEqual(preferredMode(), CLOUD));
    expect(rememberedMode() !== preferredMode() || localStorage.getItem(KEY) !== null,
      'the two only agree once a choice exists');
  });
});
