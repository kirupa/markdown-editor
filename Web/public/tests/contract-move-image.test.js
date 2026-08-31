// The web build's `moveImage` measured against the compiled Swift.
//
// `Contract/formatting.jsonl` is generated from `MarkdownFormatting.swift` and
// is the agreed description of what every port must produce. The hand-written
// suite in `move-image.test.js` says what the behaviour *should* be; this says
// the web produces byte-for-byte what macOS produces, across every corpus
// document at every interesting offset.
//
// That matters more here than for most commands. Moving a picture has two rules
// with no visible symptom when they are subtly wrong — the destination shifts
// by the removed block, and blank lines around the picture are collapsed — so a
// port can look right on a handful of examples and still disagree with the
// native build on the document somebody actually has.

import { suite, test, expect } from './harness.js';
import { moveImage } from '../app/core/formatting.js';
import { makeRange } from '../app/core/range.js';
import { readImage } from '../app/core/formatting.js';

const fixture = await loadFixture();

// `Contract/` sits outside `Web/public`: it is a build artefact of the Swift
// package, not something to serve. So this runs under node, which reads it off
// disk, and the browser page skips it rather than failing on a fetch that can
// never succeed.
async function loadFixture() {
  if (typeof process === 'undefined' || !process.versions?.node) return null;
  const url = new URL('../../../Contract/formatting.jsonl', import.meta.url);
  const { readFile } = await import('node:fs/promises');
  const text = await readFile(url, 'utf8');
  const lines = text.split('\n').filter((line) => line.length > 0);
  const header = JSON.parse(lines[0]);
  const documents = new Map(header.documents.map((d) => [d.id, d.text]));
  const cases = lines
    .slice(1)
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.command === 'moveImage');
  return { documents, cases };
}

/**
 * The first image reference in `text`, found the same way
 * `ContractFixtures.firstImageRange` finds it: by asking `readImage`, so the
 * fixture and the code under test agree on what an image is.
 */
function firstImageRange(text) {
  for (let start = 0; start < text.length; start += 1) {
    const code = text.charCodeAt(start);
    if (code !== 0x21 && code !== 0x3c) continue; // ! or <
    for (let end = text.length; end > start; end -= 1) {
      const candidate = makeRange(start, end - start);
      if (readImage(text, candidate) !== null) return candidate;
    }
  }
  return null;
}

/** Apply the fixture's minimal edit, so we compare the same way it was made. */
function applyEdit(text, entry) {
  const [location, length] = entry.replace;
  return text.slice(0, location) + entry.with + text.slice(location + length);
}

suite('Contract: moving an image', () => {
  test('the fixture is present and covers moveImage', () => {
    if (fixture === null) return; // browser: skipped by design
    expect(fixture.cases.length > 0, 'no moveImage cases in the contract');
  });

  test('every case produces the same text as the Swift build', () => {
    if (fixture === null) return;
    let checked = 0;
    for (const entry of fixture.cases) {
      const text = fixture.documents.get(entry.document);
      expect(text !== undefined, `unknown document ${entry.document}`);
      const image = firstImageRange(text);
      const result = moveImage(
        text,
        image ?? makeRange(0, 0),
        entry.selection[0]
      );
      const expected = applyEdit(text, entry);
      expect(
        result.text === expected,
        `${entry.document} @ ${entry.selection[0]}\n` +
          `  web:   ${JSON.stringify(result.text)}\n` +
          `  swift: ${JSON.stringify(expected)}`
      );
      checked += 1;
    }
    expect(checked > 0, 'no cases were checked');
  });

  test('every case leaves the same selection as the Swift build', () => {
    if (fixture === null) return;
    for (const entry of fixture.cases) {
      const text = fixture.documents.get(entry.document);
      const image = firstImageRange(text);
      const result = moveImage(
        text,
        image ?? makeRange(0, 0),
        entry.selection[0]
      );
      const [location, length] = entry.selectionAfter;
      expect(
        result.selection.location === location && result.selection.length === length,
        `${entry.document} @ ${entry.selection[0]}: ` +
          `web ${result.selection.location},${result.selection.length} ` +
          `vs swift ${location},${length}`
      );
    }
  });
});
