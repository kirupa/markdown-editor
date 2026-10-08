// Editing through the rendered view, measured against the compiled Swift.
//
// `Contract/edits.jsonl` is generated from
// `MarkdownIncrementalRenderer.sourceRange(replacing:with:)`: every line break
// the rendered view shows, in every corpus document, removed three ways. Each
// case says which Markdown that edit replaces. The rule is easy to get subtly
// wrong — a marker length that disagrees with the parser by one space, a CRLF
// split in half, a fence line that renders nothing taken along with the line
// below it — and every one of those looks right on the bug report's own
// document. So this checks the web against the Swift on all of them.

import { suite, test, expect } from './harness.js';
import { renderMarkdown } from '../app/core/render-model.js';
import { makeRange } from '../app/core/range.js';

const fixture = await loadFixture();

// `Contract/` sits outside `Web/public`, so this runs under node and the
// browser page skips it, as `contract-move-image.test.js` does.
async function loadFixture() {
  if (typeof process === 'undefined' || !process.versions?.node) return null;
  const url = new URL('../../../Contract/edits.jsonl', import.meta.url);
  const { readFile } = await import('node:fs/promises');
  const text = await readFile(url, 'utf8');
  const lines = text.split('\n').filter((line) => line.length > 0);
  const header = JSON.parse(lines[0]);
  return {
    header,
    documents: new Map(header.documents.map((d) => [d.id, d])),
    cases: lines.slice(1).map((line) => JSON.parse(line)),
  };
}

suite('Contract: editing through the rendered view', () => {
  test('the fixture is present and covers every kind of edit', () => {
    if (fixture === null) return; // browser: skipped by design
    expect(
      fixture.cases.length === fixture.header.caseCount,
      `${fixture.cases.length} cases against a header promising ${fixture.header.caseCount}`
    );
    const kinds = new Set(fixture.cases.map((entry) => entry.kind));
    for (const kind of ['join', 'joinTyping', 'deleteLine']) {
      expect(kinds.has(kind), `no ${kind} cases in the contract`);
    }
    expect(
      fixture.documents.has('empty-heading-under-quote'),
      'the document from the bug report is missing'
    );
  });

  // Offsets into the rendered text mean nothing if the two renderers disagree
  // about what that text is, so this is checked first and on its own.
  test('every document renders to the text the cases are measured in', () => {
    if (fixture === null) return;
    for (const document of fixture.documents.values()) {
      const rendered = renderMarkdown(document.text).text;
      expect(
        rendered === document.rendered,
        `${document.id}\n` +
          `  web:   ${JSON.stringify(rendered)}\n` +
          `  swift: ${JSON.stringify(document.rendered)}`
      );
    }
  });

  test('every edit replaces the same Markdown as the Swift build', () => {
    if (fixture === null) return;
    const models = new Map();
    let checked = 0;
    for (const entry of fixture.cases) {
      const document = fixture.documents.get(entry.document);
      expect(document !== undefined, `unknown document ${entry.document}`);
      if (!models.has(entry.document)) {
        models.set(entry.document, renderMarkdown(document.text));
      }
      const [location, length] = entry.rendered;
      const range = models
        .get(entry.document)
        .sourceRangeReplacing(makeRange(location, length), entry.with);
      expect(
        range.location === entry.source[0] && range.length === entry.source[1],
        `${entry.document} ${entry.kind} [${entry.rendered}] with ${JSON.stringify(entry.with)}: ` +
          `web [${range.location},${range.length}] vs swift [${entry.source}]`
      );
      checked += 1;
    }
    expect(checked > 250, `only ${checked} cases were checked`);
  });

  // The report itself: ⌫ on the empty heading line under a quote takes the
  // hidden `## ` with the line break, so nothing that was hidden surfaces.
  test('the bug report document joins without surfacing its heading marker', () => {
    if (fixture === null) return;
    const document = fixture.documents.get('empty-heading-under-quote');
    const model = renderMarkdown(document.text);
    const emptyLine = document.rendered.indexOf('\n\n') + 1;
    const range = model.sourceRangeReplacing(makeRange(emptyLine - 1, 1), '');
    const edited =
      document.text.slice(0, range.location) +
      document.text.slice(range.location + range.length);
    const after = renderMarkdown(edited).text;
    expect(!after.includes('#'), `a hidden marker surfaced: ${JSON.stringify(after)}`);
    expect(
      after === document.rendered.slice(0, emptyLine - 1) + document.rendered.slice(emptyLine),
      `the view should lose exactly the line break: ${JSON.stringify(after)}`
    );
  });
});
