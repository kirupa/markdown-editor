import { suite, test, expect, expectEqual } from './harness.js';
import { moveImage } from '../app/core/formatting.js';
import { makeRange } from '../app/core/range.js';

// The same expectations as `MoveImageTests` in the Swift core, so a picture
// moved on the web lands exactly where it lands on macOS. Moving a picture is a
// block move, not a text splice: the first macOS version inserted at whatever
// character the pointer was nearest, which turned a drop aimed at the gap above
// a paragraph into `Ome![photo](a.png)ga paragraph.` — a real result from a real
// drag.
suite('Moving an image', () => {
  const image = '![photo](a.png)';
  const document = `# Drag\n\nAlpha paragraph.\n\n${image}\n\nOmega paragraph.\n`;
  const imageRange = makeRange('# Drag\n\nAlpha paragraph.\n\n'.length, image.length);

  test('a drop inside a word still lands between the lines', () => {
    // Aimed at the middle of "Omega", which is what the pointer was over.
    const inside = document.indexOf('Omega') + 3;
    const result = moveImage(document, imageRange, inside);
    // Assert the words survived, not that some substring is absent. The picture
    // is inserted with a blank line either side, so splicing it into "Omega"
    // yields "Ome\n\n![photo](a.png)\n\nga" — which passes a check for
    // "Ome![photo]" while the word is still destroyed. That weaker assertion let
    // a deliberately broken build through twice on macOS.
    expect(result.text.includes('Omega paragraph.'), result.text);
    expect(result.text.includes('Alpha paragraph.'), result.text);
    expect(result.text.includes('# Drag'), result.text);
  });

  test('no word is ever broken, wherever it is dropped', () => {
    const words = ['# Drag', 'Alpha paragraph.', 'Omega paragraph.'];
    for (let target = 0; target <= document.length; target += 1) {
      const result = moveImage(document, imageRange, target);
      for (const word of words) {
        expect(
          result.text.includes(word),
          `dropping at ${target} broke ${JSON.stringify(word)}: ${JSON.stringify(result.text)}`
        );
      }
    }
  });

  test('moving below the last paragraph puts it at the end as its own block', () => {
    const result = moveImage(document, imageRange, document.length);
    expectEqual(
      result.text,
      `# Drag\n\nAlpha paragraph.\n\nOmega paragraph.\n\n${image}`
    );
  });

  test('moving above the first paragraph puts it before it', () => {
    const target = document.indexOf('Alpha');
    const result = moveImage(document, imageRange, target);
    expectEqual(
      result.text,
      `# Drag\n\n${image}\n\nAlpha paragraph.\n\nOmega paragraph.\n`
    );
  });

  test('the picture does not leave an empty paragraph behind', () => {
    const target = document.indexOf('Alpha');
    const result = moveImage(document, imageRange, target);
    expect(!result.text.includes('\n\n\n'), JSON.stringify(result.text));
  });

  test('the picture is always separated by a blank line either side', () => {
    for (const target of [0, 8, 12, document.indexOf('Omega')]) {
      const result = moveImage(document, imageRange, target);
      const at = result.text.indexOf(image);
      expect(at !== -1, `no image after dropping at ${target}`);
      if (at > 0) {
        expect(
          result.text.slice(0, at).endsWith('\n\n'),
          `no blank line before, target ${target}: ${JSON.stringify(result.text)}`
        );
      }
      const after = result.text.slice(at + image.length);
      if (after.length > 0) {
        expect(
          after.startsWith('\n\n'),
          `no blank line after, target ${target}: ${JSON.stringify(result.text)}`
        );
      }
    }
  });

  test('the moved picture stays selected', () => {
    const target = document.indexOf('Alpha');
    const result = moveImage(document, imageRange, target);
    expectEqual(
      result.text.substr(result.selection.location, result.selection.length),
      image
    );
  });

  test('dropping a picture on itself changes nothing', () => {
    for (let offset = imageRange.location; offset <= imageRange.location + imageRange.length; offset += 1) {
      const result = moveImage(document, imageRange, offset);
      expectEqual(result.text, document, `offset ${offset} rewrote the document`);
    }
  });

  test('a picture sitting inside a sentence takes only itself', () => {
    const text = `Before ${image} after.\n\nTail.\n`;
    const range = makeRange(7, image.length);
    const result = moveImage(text, range, text.length);
    expect(result.text.includes('Before  after.'), JSON.stringify(result.text));
    expect(result.text.endsWith(image), JSON.stringify(result.text));
  });

  test('a range that is not an image is refused', () => {
    const text = 'Just some words';
    expectEqual(moveImage(text, makeRange(0, 4), 10).text, text);
  });

  test('an empty range is refused', () => {
    const text = `AB${image}`;
    expectEqual(moveImage(text, makeRange(2, 0), 0).text, text);
  });

  test('offsets past the end are clamped, not crashed into', () => {
    expect(moveImage(document, imageRange, 9999).text.includes(image));
    expectEqual(moveImage('AB', makeRange(1, 500), 0).text, 'AB');
  });

  test('an HTML img tag moves as one piece and keeps its size', () => {
    const tag = '<img src="a.png" width="320" height="200">';
    const text = `${tag}\n\nTail.\n`;
    const result = moveImage(text, makeRange(0, tag.length), text.length);
    expect(result.text.includes('width="320"'), JSON.stringify(result.text));
    expect(result.text.includes('height="200"'), JSON.stringify(result.text));
    expect(result.text.endsWith(tag), JSON.stringify(result.text));
  });

  test('moving twice returns the document to where it started', () => {
    const away = moveImage(document, imageRange, document.length);
    expectEqual(away.text, `# Drag\n\nAlpha paragraph.\n\nOmega paragraph.\n\n${image}`);
    const back = moveImage(away.text, away.selection, away.text.indexOf('Omega'));
    expectEqual(back.text, document);
  });

  test('a document that is nothing but the picture survives a move', () => {
    expectEqual(moveImage(image, makeRange(0, image.length), 0).text, image);
  });
});
