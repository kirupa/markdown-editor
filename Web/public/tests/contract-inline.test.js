// The web build's inline commands measured against the compiled Swift.
//
// `Contract/formatting.jsonl` is generated from `MarkdownFormatting.swift` and
// is the agreed description of what every port must produce. The hand-written
// suite in `formatting.test.js` says what the behaviour *should* be; this says
// the web produces byte-for-byte what the native builds produce, across every
// corpus document at every interesting selection.
//
// It was added with the rule that formatting refuses inside code. That rule is
// the kind a port silently gets wrong: nothing looks broken, because the only
// difference is a command that does nothing, and the corpus has exactly two
// documents with code in them. Replaying the fixture is the only way to be sure
// the browser and the Mac refuse in the same places and nowhere else.

import { suite, test, expect } from './harness.js';
import { toggleInline, insertLink } from '../app/core/formatting.js';

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
    .filter((entry) => entry.command === 'toggleInline' || entry.command === 'insertLink');
  return { documents, cases };
}

/** Apply the fixture's minimal edit, so we compare the same way it was made. */
function applyEdit(text, entry) {
  const [location, length] = entry.replace;
  return text.slice(0, location) + entry.with + text.slice(location + length);
}

function run(entry, text) {
  const selection = { location: entry.selection[0], length: entry.selection[1] };
  return entry.command === 'insertLink'
    ? insertLink(entry.argument, text, selection)
    : toggleInline(entry.argument, text, selection);
}

suite('Contract: inline styles and links', () => {
  test('the fixture is present and covers the inline commands', () => {
    if (fixture === null) return; // browser: skipped by design
    expect(fixture.cases.length > 0, 'no toggleInline cases in the contract');
  });

  test('every case produces the same text and selection as the Swift build', () => {
    if (fixture === null) return;
    let checked = 0;
    for (const entry of fixture.cases) {
      const text = fixture.documents.get(entry.document);
      expect(text !== undefined, `unknown document ${entry.document}`);
      const result = run(entry, text);
      const expected = applyEdit(text, entry);
      const where = `${entry.command} ${entry.argument} in ${entry.document} @ [${entry.selection}]`;
      expect(
        result.text === expected,
        `${where}\n` +
          `  web:   ${JSON.stringify(result.text)}\n` +
          `  swift: ${JSON.stringify(expected)}`
      );
      expect(
        result.selection.location === entry.selectionAfter[0] &&
          result.selection.length === entry.selectionAfter[1],
        `${where}\n` +
          `  web:   [${result.selection.location}, ${result.selection.length}]\n` +
          `  swift: [${entry.selectionAfter}]`
      );
      checked += 1;
    }
    expect(checked === fixture.cases.length, 'not every case was checked');
  });

  test('the code document contributes refusals inside its fence', () => {
    if (fixture === null) return;
    // A blanket "no edit" check would be wrong: selecting only a trailing
    // newline has always been a no-op in every document. So this names the
    // place the rule is about — the corpus's fenced block — and requires every
    // case that lands inside it to record a refusal.
    const text = fixture.documents.get('code');
    const start = text.indexOf('```swift');
    const end = text.indexOf('```', text.indexOf('\n', start)) + 3;
    const inside = fixture.cases.filter(
      (entry) =>
        entry.document === 'code' &&
        entry.selection[0] >= start &&
        entry.selection[0] + entry.selection[1] <= end
    );
    expect(inside.length > 0, `no cases inside the fence at [${start}, ${end})`);
    for (const entry of inside) {
      expect(
        entry.with === '',
        `${entry.command} ${entry.argument} @ [${entry.selection}] still edits inside the fence`
      );
    }
  });
});
