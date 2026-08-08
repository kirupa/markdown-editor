// How an image with a size is written, and read back.
//
// Markdown has no syntax for dimensions, so a sized image is HTML. That makes
// this module the boundary between a format that is forgiving (HTML, where
// attributes come in any order and quoting is optional) and one that is not
// (the document text, which has to round-trip exactly). Everything here is
// about that boundary.

import { suite, test, expect, expectEqual } from './harness.js';
import {
  parseImageTag,
  imageReference,
  markdownImageReference,
  proportionalSize,
} from '../app/core/image-tag.js';

/** Parses a whole string as one tag. */
function parse(text) {
  return parseImageTag(text, 0, text.length);
}

suite('Image tags', () => {
  test('a tag with a source is an image', () => {
    const tag = parse('<img src="a.png" alt="A photo" width="300" height="200">');
    expectEqual(tag.destination, 'a.png');
    expectEqual(tag.altText, 'A photo');
    expectEqual(tag.width, 300);
    expectEqual(tag.height, 200);
    expectEqual(tag.end, 56, 'and it reports where it ended');
  });

  test('attributes are read in any order, quoted either way or not at all', () => {
    const variants = [
      '<img width="300" src="a.png">',
      "<img src='a.png' width='300'>",
      '<img src=a.png width=300>',
      '<img   src = "a.png"   width = "300"  >',
      '<IMG SRC="a.png" WIDTH="300">',
      '<img src="a.png" width="300"/>',
    ];
    for (const text of variants) {
      const tag = parse(text);
      expect(tag !== null, `parsed: ${text}`);
      expectEqual(tag.destination, 'a.png', text);
      expectEqual(tag.width, 300, text);
    }
  });

  test('a quoted value may contain the characters that would end the tag', () => {
    const tag = parse(`<img src="a.png" alt="a > b, 'quoted'">`);
    expectEqual(tag.altText, "a > b, 'quoted'");
    expectEqual(tag.destination, 'a.png');
  });

  test('entities in an attribute are decoded', () => {
    const tag = parse('<img src="a.png?x=1&amp;y=2" alt="&quot;Hi&quot; &lt;&gt; &#65;">');
    expectEqual(tag.destination, 'a.png?x=1&y=2');
    expectEqual(tag.altText, '"Hi" <> A');
  });

  test('an element that merely starts with img is not an image', () => {
    // `<imgx>` shares a prefix and nothing else.
    for (const text of ['<imgx src="a.png">', '<image src="a.png">', '<div src="a.png">']) {
      expectEqual(parse(text), null, text);
    }
  });

  test('a tag with nothing to draw is not an image', () => {
    // Left as text on purpose: an author can see and fix a tag they can read,
    // and cannot fix an empty box.
    expectEqual(parse('<img>'), null);
    expectEqual(parse('<img alt="nothing" width="10">'), null);
    expectEqual(parse('<img src="">'), null);
  });

  test('an unterminated tag is not an image', () => {
    expectEqual(parse('<img src="a.png"'), null);
    expectEqual(parse('<img src="a.png'), null, 'nor is an unclosed quote');
  });

  test('a size that is not a pixel count is simply absent', () => {
    // `50%` is legal HTML this editor cannot show in a number field. The image
    // still renders; there is just no number to offer, and nothing the author
    // wrote by hand gets quietly rewritten.
    const tag = parse('<img src="a.png" width="50%" height="0">');
    expectEqual(tag.destination, 'a.png');
    expectEqual(tag.width, null);
    expectEqual(tag.height, null);
  });

  test('a tag inside a longer line reports where it ends', () => {
    const line = 'Before <img src="a.png"> after';
    const tag = parseImageTag(line, 7, line.length);
    expectEqual(line.slice(7, tag.end), '<img src="a.png">');
  });
});

suite('Writing an image reference', () => {
  test('an image with no size is plain Markdown', () => {
    // The common case stays the common syntax. HTML shows up only when it buys
    // something, which for an unsized image it does not.
    expectEqual(
      imageReference({ destination: 'Post.assets/photo.png', altText: 'Photo' }),
      '![Photo](Post.assets/photo.png)'
    );
  });

  test('an image with a size is HTML', () => {
    expectEqual(
      imageReference({ destination: 'a.png', altText: 'Photo', width: 300, height: 200 }),
      '<img src="a.png" alt="Photo" width="300" height="200">'
    );
  });

  test('one dimension on its own is written on its own', () => {
    // A lone width lets the renderer derive the height from the real image,
    // which is more accurate than any number written here.
    expectEqual(
      imageReference({ destination: 'a.png', altText: '', width: 300 }),
      '<img src="a.png" alt="" width="300">'
    );
    expectEqual(
      imageReference({ destination: 'a.png', altText: '', height: 200 }),
      '<img src="a.png" alt="" height="200">'
    );
  });

  test('what is written parses back to what was asked for', () => {
    const cases = [
      { destination: 'a.png', altText: 'Photo', width: 300, height: 200 },
      { destination: 'dir/a b.png', altText: '', width: 12 },
      { destination: 'a.png?x=1&y=2', altText: 'He said "hi" <loudly>', width: 5, height: 7 },
    ];
    for (const original of cases) {
      const tag = parse(imageReference(original));
      expectEqual(tag.destination, original.destination);
      expectEqual(tag.altText, original.altText);
      expectEqual(tag.width, original.width ?? null);
      expectEqual(tag.height, original.height ?? null);
    }
  });

  test('characters that would break out of an attribute are escaped', () => {
    const written = imageReference({
      destination: 'a.png', altText: '" onerror="alert(1)', width: 10,
    });
    expect(!written.includes('" onerror='), 'the quote cannot close the attribute');
    expectEqual(parse(written).altText, '" onerror="alert(1)', 'and it still round-trips');
  });

  test('a Markdown label escapes the brackets that would end it', () => {
    expectEqual(
      markdownImageReference('a [b] c', 'a.png'),
      '![a \\[b\\] c](a.png)'
    );
  });

  test('a size of zero or nonsense is treated as no size at all', () => {
    for (const size of [0, -5, null, undefined, NaN, 'wide']) {
      expectEqual(
        imageReference({ destination: 'a.png', altText: '', width: size }),
        '![](a.png)',
        String(size)
      );
    }
  });
});

suite('Keeping an image in proportion', () => {
  const natural = { width: 1600, height: 900 };

  test('typing a width derives the height', () => {
    expectEqual(proportionalSize({ width: 800, natural, edited: 'width' }),
      { width: 800, height: 450 });
  });

  test('typing a height derives the width', () => {
    expectEqual(proportionalSize({ height: 450, natural, edited: 'height' }),
      { width: 800, height: 450 });
  });

  test('the number that was typed is the one that is kept exactly', () => {
    // 777 does not divide evenly, and the typed number must survive anyway —
    // otherwise the field fights the person typing in it.
    const sized = proportionalSize({ width: 777, natural, edited: 'width' });
    expectEqual(sized.width, 777);
    expectEqual(sized.height, 437, 'the derived side rounds');
  });

  test('a very wide image never derives a height of zero', () => {
    // Rounding 0.4 to 0 would make the picture vanish, so it is kept away
    // from zero deliberately.
    const sized = proportionalSize({
      width: 10, natural: { width: 4000, height: 100 }, edited: 'width',
    });
    expectEqual(sized.height, 1);
  });

  test('with no natural size nothing is derived', () => {
    // An image that has not loaded has no shape to preserve. Inventing one
    // would distort the picture the moment it did load.
    expectEqual(proportionalSize({ width: 300, natural: null, edited: 'width' }),
      { width: 300, height: null });
  });

  test('clearing the size clears both sides', () => {
    expectEqual(proportionalSize({ width: null, natural, edited: 'width' }),
      { width: null, height: null });
  });
});
