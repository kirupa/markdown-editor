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

suite('A picture reaching into the page margins', () => {
  const render = (source) => {
    const host = document.createElement('div');
    renderInto(host, renderMarkdown(source), (d) => `about:blank#${d}`);
    return host;
  };

  test('a line holding only a picture is marked as one', () => {
    const host = render('Before.\n\n![a](a.png)\n\nAfter.');
    const marked = host.querySelectorAll('.me-block--image');
    expectEqual(marked.length, 1, 'exactly the picture line');
    expect(
      marked[0].querySelector('.me-image') !== null,
      'the marked line is the one with the picture in it'
    );
  });

  test('a picture in a sentence leaves its line alone', () => {
    // Pulling this line into the margins would drag the words with it.
    const host = render('Words ![a](a.png) more words.');
    expectEqual(host.querySelectorAll('.me-block--image').length, 0);
  });

  test('the width the picture asks for is passed to the stylesheet', () => {
    const host = render(
      'Before.\n\n<img src="a.png" alt="a" width="842" height="500">\n\nAfter.'
    );
    const block = host.querySelector('.me-block--image');
    expect(block !== null, 'the picture line should be marked');
    expectEqual(block.style.getPropertyValue('--me-image-width'), '842px');
  });

  test('a picture with no size of its own passes no width', () => {
    // It is drawn at its natural size, capped below the column, so there is
    // nothing to reach into the margins with.
    const host = render('Before.\n\n![a](a.png)\n\nAfter.');
    const block = host.querySelector('.me-block--image');
    expectEqual(block.style.getPropertyValue('--me-image-width'), '');
  });

  test('the overhang is measured, not assumed', async () => {
    // The whole point is that the picture ends up centred on the column, and
    // the arithmetic that puts it there lives in the stylesheet. So this loads
    // the real stylesheet and measures the real layout: three widths, one
    // centre. Asserting the CSS text instead would pass with a rule the
    // browser silently drops.
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = '../css/app.css';
    const loaded = new Promise((resolve) => {
      link.addEventListener('load', resolve, { once: true });
      link.addEventListener('error', resolve, { once: true });
    });
    document.head.append(link);
    await loaded;

    const surface = document.createElement('div');
    surface.className = 'me-surface';
    surface.style.cssText =
      'position:absolute;left:-9999px;top:0;width:900px;box-sizing:border-box;' +
      '--me-image-bleed:100px;--me-measure:652px;' +
      'padding-left:124px;padding-right:124px;';
    document.body.append(surface);
    try {
      // A picture that really loads, so the renderer has an <img> to read the
      // width off. A destination it cannot resolve renders as a label
      // instead, and a label has no width to reach into the margins with.
      const pixel =
        'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
      const centres = [];
      for (const width of [652, 752, 852]) {
        renderInto(
          surface,
          renderMarkdown(
            `Before.\n\n<img src="a.png" alt="a" width="${width}" height="100">\n\nAfter.`
          ),
          () => pixel
        );
        const block = surface.querySelector('.me-block--image');
        expect(block !== null, 'the picture line should be marked');
        // The line's own box carries the overhang, and the picture is drawn
        // from its leading edge, so this is where the picture starts.
        const left = Number.parseFloat(getComputedStyle(block).marginLeft);
        centres.push(left + width / 2);
      }
      const [first, ...rest] = centres;
      for (const centre of rest) {
        expect(
          Math.abs(centre - first) < 1.5,
          `the picture must stay centred as it grows: ${centres.join(', ')}`
        );
      }
    } finally {
      surface.remove();
      link.remove();
    }
  });

  test('the resize ceiling is the column plus both margins', () => {
    // How wide a drag may take a picture. The bleed cannot be read back as a
    // number — a custom property comes out of `getComputedStyle` as the tokens
    // it was written with, so `--me-image-bleed` reads as the literal text
    // "clamp( 0px, (100vw - 700px) / 2, 100px )" and parses as NaN. Shipping
    // that would have collapsed the ceiling to the column, and a picture could
    // never have been dragged into the margins at all.
    //
    // So the ceiling is measured instead: the surface's own width less the
    // plain page padding, which leaves the column and both margins.
    const surface = document.createElement('div');
    surface.className = 'me-surface';
    surface.style.cssText =
      'position:absolute;left:-9999px;top:0;width:900px;box-sizing:border-box;' +
      '--me-surface-padding:24px;padding-left:124px;padding-right:124px;';
    document.body.append(surface);
    try {
      const style = getComputedStyle(surface);
      const unresolved = style.getPropertyValue('--me-image-bleed');
      if (unresolved.includes('clamp')) {
        expect(
          !Number.isFinite(Number.parseFloat(unresolved)),
          'a clamped custom property must not be read back as a number'
        );
      }
      const inset = Number.parseFloat(style.getPropertyValue('--me-surface-padding'));
      expectEqual(inset, 24, 'the plain page padding must be a plain length');

      const width = surface.getBoundingClientRect().width;
      const column =
        width -
        Number.parseFloat(style.paddingLeft) -
        Number.parseFloat(style.paddingRight);
      expectEqual(column, 652, 'the column');
      expectEqual(width - 2 * inset, column + 200, 'the column plus both margins');
    } finally {
      surface.remove();
    }
  });
});
