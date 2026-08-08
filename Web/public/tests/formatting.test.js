import { suite, test, expect, expectEqual } from './harness.js';
import {
  InlineStyle,
  ListStyle,
  toggleInline,
  applyHeading,
  toggleList,
  toggleQuote,
  wrapCodeBlock,
  insertNewline,
  insertLink,
  insertHorizontalRule,
  insertImage,
  setImageSize,
} from '../app/core/formatting.js';

// ── Minimal inline renderer ──────────────────────────────────────────────────
//
// Several tests use MarkdownRenderer.render(text).text to verify that the
// produced Markdown round-trips correctly.  The full renderer lives in
// render-model.js; this minimal version handles the specific inline constructs
// exercised by the formatting tests.

const MarkdownRenderer = {
  render(markdown) {
    let text = markdown;

    // Code spans take priority; process them before other inline patterns.
    // CommonMark: strip exactly one leading and trailing space when the content
    // starts and ends with a space but is not entirely spaces.
    text = text.replace(/(`+)([\s\S]*?)\1/g, (_match, _delim, content) => {
      if (
        content.length >= 2 &&
        content[0] === ' ' &&
        content[content.length - 1] === ' ' &&
        content.trim().length > 0
      ) {
        return content.slice(1, -1);
      }
      return content;
    });

    // Inline links: extract and unescape the label.
    text = text.replace(/\[(?:[^\]\\]|\\.)*\]\((?:[^)\\]|\\.)*\)/g, (match) => {
      const labelMatch = match.match(/^\[(?:[^\]\\]|\\.)*\]/);
      if (!labelMatch) return match;
      const label = labelMatch[0].slice(1, -1);
      return label.replace(/\\(.)/gs, '$1');
    });

    // Bold (** and __)
    text = text.replace(/\*\*([\s\S]+?)\*\*/g, '$1');
    text = text.replace(/__([\s\S]+?)__/g, '$1');

    // Italic (* and _)
    text = text.replace(/\*([\s\S]+?)\*/g, '$1');
    text = text.replace(/_([\s\S]+?)_/g, '$1');

    // Strikethrough
    text = text.replace(/~~([\s\S]+?)~~/g, '$1');

    // Underline HTML tag
    text = text.replace(/<u>([\s\S]*?)<\/u>/g, '$1');

    return { text };
  },
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Build a plain {location, length} range. */
function r(location, length) {
  return { location, length };
}

/** Find the first occurrence of `needle` in `haystack` and return its range. */
function rangeOf(haystack, needle) {
  const loc = haystack.indexOf(needle);
  if (loc === -1) throw new Error(`"${needle}" not found in "${haystack}"`);
  return r(loc, needle.length);
}

/** Extract the substring addressed by a {location,length} range. */
function sub(text, range) {
  return text.slice(range.location, range.location + range.length);
}

// ── Tests ────────────────────────────────────────────────────────────────────

suite('Markdown formatting', () => {
  test('Inline styles wrap Unicode selection', () => {
    const text = 'Use 🌱 here';
    const selection = rangeOf(text, '🌱');

    const result = toggleInline(InlineStyle.bold, text, selection);

    expectEqual(result.text, 'Use **🌱** here');
    expectEqual(sub(result.text, result.selection), '🌱');
  });

  test('Inline style toggles off around selected content', () => {
    const text = 'Use **bold** here';
    const selection = rangeOf(text, 'bold');

    const result = toggleInline(InlineStyle.bold, text, selection);

    expectEqual(result.text, 'Use bold here');
    expectEqual(result.selection, r(4, 4));
  });

  test('Empty inline selection inserts a selected placeholder', () => {
    const result = toggleInline(InlineStyle.italic, 'hello', r(5, 0));

    expectEqual(result.text, 'hello*italic text*');
    expectEqual(result.selection, r(6, 11));
  });

  test('Empty bold insertion is not a thematic break', () => {
    const result = toggleInline(InlineStyle.bold, '', r(0, 0));

    expectEqual(result.text, '**bold text**');
    expectEqual(MarkdownRenderer.render(result.text).text, 'bold text');
  });

  test('Italic combines with a fully selected bold token', () => {
    const result = toggleInline(InlineStyle.italic, '**bold**', r(0, 8));

    expectEqual(result.text, '***bold***');
  });

  test('Combined bold and italic toggle independently', () => {
    const italicOff = toggleInline(InlineStyle.italic, '***bold***', r(0, 10));
    const boldOff   = toggleInline(InlineStyle.bold,   '***bold***', r(0, 10));

    expectEqual(italicOff.text, '**bold**');
    expectEqual(boldOff.text,   '*bold*');
  });

  test('Combined styles toggle from content-only selection', () => {
    const italicOff = toggleInline(InlineStyle.italic, '***bold***', r(3, 4));
    const boldOff   = toggleInline(InlineStyle.bold,   '___bold___', r(3, 4));

    expectEqual(italicOff.text, '**bold**');
    expectEqual(boldOff.text,   '_bold_');
  });

  test('Underscore styles toggle off', () => {
    const italic   = toggleInline(InlineStyle.italic, '_word_',     r(0, 6));
    const bold     = toggleInline(InlineStyle.bold,   '__word__',   r(0, 8));
    const combined = toggleInline(InlineStyle.italic, '___word___', r(0, 10));

    expectEqual(italic.text,   'word');
    expectEqual(bold.text,     'word');
    expectEqual(combined.text, '__word__');
  });

  test('Emphasis keeps selected boundary whitespace outside markers', () => {
    const result = toggleInline(InlineStyle.bold, 'word ', r(0, 5));

    expectEqual(result.text, '**word** ');
    expectEqual(MarkdownRenderer.render(result.text).text, 'word ');
  });

  test('Inline code round trips meaningful boundary spaces', () => {
    const text = ' foo ';
    const wrapped = toggleInline(InlineStyle.inlineCode, text, r(0, 5));

    const unwrapped = toggleInline(
      InlineStyle.inlineCode,
      wrapped.text,
      r(0, wrapped.text.length)
    );

    expectEqual(MarkdownRenderer.render(wrapped.text).text, text);
    expectEqual(unwrapped.text, text);

    const renderedToggle = toggleInline(
      InlineStyle.inlineCode,
      wrapped.text,
      wrapped.selection
    );
    expectEqual(renderedToggle.text, text);
  });

  test('Heading replaces an existing heading marker', () => {
    const result = applyHeading(3, '## Heading\nBody', r(4, 0));

    expectEqual(result.text, '### Heading\nBody');
    expectEqual(result.selection, r(5, 0));
  });

  test('Heading applies to an empty final line', () => {
    const result = applyHeading(2, 'Body\n', r(5, 0));

    expectEqual(result.text, 'Body\n## ');
    expectEqual(result.selection, r(8, 0));
  });

  test('Bulleted list applies to every selected line', () => {
    const text = 'one\ntwo\nthree';
    const result = toggleList(ListStyle.bulleted, text, r(0, text.length));

    expectEqual(result.text, '- one\n- two\n- three');
    expectEqual(sub(result.text, result.selection), 'one\n- two\n- three');
  });

  test('Bulleted list toggles off', () => {
    const text = '- one\n- two';
    const result = toggleList(ListStyle.bulleted, text, r(2, 7));

    expectEqual(result.text, 'one\ntwo');
  });

  test('Numbered list replaces other list markers', () => {
    const text = '- one\n- two';
    const result = toggleList(ListStyle.numbered, text, r(0, text.length));

    expectEqual(result.text, '1. one\n2. two');
  });

  test('Task list adds checkboxes', () => {
    const result = toggleList(ListStyle.task, 'one\ntwo', r(0, 7));

    expectEqual(result.text, '- [ ] one\n- [ ] two');
  });

  test('Quote toggles selected lines', () => {
    const text = 'one\ntwo';
    const quoted = toggleQuote(text, r(0, 7));
    const unquoted = toggleQuote(quoted.text, r(2, quoted.text.length - 2));

    expectEqual(quoted.text, '> one\n> two');
    expectEqual(unquoted.text, text);
  });

  test('Code block wraps and selects original content', () => {
    const result = wrapCodeBlock('let value = 1', r(0, 13));

    expectEqual(result.text, '```\nlet value = 1\n```');
    expectEqual(sub(result.text, result.selection), 'let value = 1');
  });

  test('Code block expands a partial selection to full lines', () => {
    const text = 'before\nselected text\nafter';
    const selection = rangeOf(text, 'text');
    const result = wrapCodeBlock(text, selection);

    expectEqual(result.text, 'before\n```\nselected text\n```\nafter');
    expectEqual(sub(result.text, result.selection), 'text');
  });

  test('Empty code block starts and ends on complete lines', () => {
    const result = wrapCodeBlock('beforeafter', r(6, 0));

    expectEqual(result.text, 'before\n```\n\n```\nafter');
    expectEqual(result.selection, r(11, 0));
  });

  test('Inline code delimiter exceeds content backtick runs', () => {
    const text = 'a`b';
    const result = toggleInline(InlineStyle.inlineCode, text, r(0, 3));

    expectEqual(result.text, '``a`b``');
    expectEqual(result.selection, r(2, 3));
  });

  test('Inline code pads content with edge backticks', () => {
    const text = 'foo`';
    const result = toggleInline(InlineStyle.inlineCode, text, r(0, 4));

    expectEqual(result.text, '`` foo` ``');
    expectEqual(result.selection, r(3, 4));

    const unwrapped = toggleInline(
      InlineStyle.inlineCode,
      result.text,
      r(0, result.text.length)
    );
    expectEqual(unwrapped.text, text);
  });

  test('Code block fence exceeds backticks in selected content', () => {
    const text = '```\ninside\n```\n';
    const result = wrapCodeBlock(text, r(0, text.length));

    expect(result.text.startsWith('````\n'), 'should start with ````\\n');
    expect(result.text.endsWith('````\n'), 'should end with ````\\n');
  });

  test('Italic uses an intraword-safe asterisk delimiter', () => {
    const result = toggleInline(InlineStyle.italic, 'foobar', r(1, 3));

    expectEqual(result.text, 'f*oob*ar');
  });

  test('Newline continues common list markers', () => {
    const bullet  = insertNewline('- item',     r(6,  0));
    const numbered = insertNewline('3. item',   r(7,  0));
    const task    = insertNewline('- [x] done', r(10, 0));

    expectEqual(bullet.text,   '- item\n- ');
    expectEqual(numbered.text, '3. item\n4. ');
    expectEqual(task.text,     '- [x] done\n- [ ] ');
  });

  test('Newline on empty list item removes its marker', () => {
    const result = insertNewline('- item\n- ', r(9, 0));

    expectEqual(result.text, '- item\n');
    expectEqual(result.selection, r(7, 0));
  });

  test('Oversized ordered marker does not overflow', () => {
    const text = '9223372036854775807. item';
    const result = insertNewline(text, r(text.length, 0));

    expectEqual(result.text, text + '\n');
  });

  test('Link wraps selected label', () => {
    const result = insertLink(
      'https://example.com/a_(b)',
      'Example',
      r(0, 7)
    );

    expectEqual(result.text, '[Example](https://example.com/a_%28b%29)');
    expectEqual(result.selection, r(1, 7));
  });

  test('Link escapes Markdown metacharacters in label', () => {
    const result = insertLink(
      'https://example.com',
      'a]b\\c',
      r(0, 5)
    );

    expectEqual(result.text, '[a\\]b\\\\c](https://example.com)');
    expectEqual(MarkdownRenderer.render(result.text).text, 'a]b\\c');
  });

  test('Horizontal rule gets surrounding line breaks', () => {
    const result = insertHorizontalRule('beforeafter', r(6, 0));

    expectEqual(result.text, 'before\n***\n\nafter');
  });
});

suite('Inserting an image by URL', () => {
  test('an image is inserted at the caret', () => {
    const out = insertImage('https://x.com/a.png', 'Photo', 'See: ', r(5, 0));
    expectEqual(out.text, 'See: ![Photo](https://x.com/a.png)');
  });

  test('the alt text is selected so it can be typed over', () => {
    const out = insertImage('https://x.com/a.png', 'Photo', '', r(0, 0));
    expectEqual(sub(out.text, out.selection), 'Photo');
  });

  test('a selection becomes the alt text when none is supplied', () => {
    // Selecting a caption and inserting an image should keep the words the
    // author already wrote rather than silently discard them.
    const out = insertImage('a.png', '', 'A red door', r(0, 10));
    expectEqual(out.text, '![A red door](a.png)');
  });

  test('a space or bracket in a URL cannot break the reference', () => {
    const out = insertImage('a b (c).png', 'x', '', r(0, 0));
    expectEqual(out.text, '![x](a%20b%20%28c%29.png)');
  });
});

suite('Resizing an image', () => {
  /** The source range of the only image reference in `text`. */
  function imageRange(text) {
    const at = text.indexOf('![') >= 0 ? text.indexOf('![') : text.indexOf('<img');
    const close = text[at] === '!' ? text.indexOf(')', at) : text.indexOf('>', at);
    return r(at, close + 1 - at);
  }

  test('sizing a Markdown image rewrites it as HTML', () => {
    // Markdown has no syntax for dimensions, so this is the one place a
    // reference has to change form. The convention is in Contract/README.md.
    const text = 'A ![Photo](a.png) here';
    const out = setImageSize(text, imageRange(text), { width: 300, height: 200 });
    expectEqual(out.text, 'A <img src="a.png" alt="Photo" width="300" height="200"> here');
  });

  test('clearing the size returns it to Markdown', () => {
    const text = '<img src="a.png" alt="Photo" width="300" height="200">';
    const out = setImageSize(text, imageRange(text), { width: null, height: null });
    expectEqual(out.text, '![Photo](a.png)');
  });

  test('resizing an already sized image keeps it as one tag', () => {
    const text = '<img src="a.png" alt="" width="300" height="200">';
    const out = setImageSize(text, imageRange(text), { width: 60, height: 40 });
    expectEqual(out.text, '<img src="a.png" alt="" width="60" height="40">');
  });

  test('the resized image stays selected', () => {
    // The size fields are driven by the selected image, so dropping the
    // selection on every keystroke would make them unusable.
    const text = 'A ![Photo](a.png) here';
    const out = setImageSize(text, imageRange(text), { width: 300, height: 200 });
    expectEqual(
      sub(out.text, out.selection),
      '<img src="a.png" alt="Photo" width="300" height="200">'
    );
  });

  test('text that is not an image is left exactly as it was', () => {
    // A stale range must never corrupt the document.
    const text = 'Just words here';
    const out = setImageSize(text, r(5, 5), { width: 300, height: 200 });
    expectEqual(out.text, text);
    expectEqual(out.selection, r(5, 5), 'and the selection is unchanged');
  });

  test('a space in the path is encoded on the way back to Markdown', () => {
    // An HTML attribute holds `my file.png` happily; the same text in Markdown
    // is not an image at all — GitHub renders it as literal text and the
    // picture is lost. Verified against GitHub's own renderer.
    const text = '<img src="my file.png" alt="P" width="9">';
    const out = setImageSize(text, imageRange(text), { width: null, height: null });
    expectEqual(out.text, '![P](my%20file.png)');
  });

  test('a percent-encoded destination survives a round trip', () => {
    const text = '![P](my%20file.png)';
    const out = setImageSize(text, imageRange(text), { width: 10, height: 10 });
    expectEqual(out.text, '<img src="my%20file.png" alt="P" width="10" height="10">');
    const back = setImageSize(out.text, imageRange(out.text), { width: null, height: null });
    expectEqual(back.text, text, 'and returns to exactly the original Markdown');
  });
});
