// The web build measured against the cross-platform contract.
//
// `Contract/render-model.json` is generated from the Swift implementation and
// is the agreed description of what every port must produce. Until now only
// the Swift side was held to it, so the two render models could drift and
// nothing would say so — a document sized on the web would quietly show raw
// HTML on macOS. This reads the same fixture the native builds read.

import { suite, test, expect, expectEqual } from './harness.js';
import { renderMarkdown } from '../app/core/render-model.js';

const fixture = await loadFixture();

// `Contract/` sits outside `Web/public`, deliberately: it is a build artefact
// of the Swift package, not something to serve. So this check runs under node,
// which reads it off disk, and the browser page says so rather than failing on
// a fetch that can never succeed.
async function loadFixture() {
  if (typeof process === 'undefined' || !process.versions?.node) return null;
  const url = new URL('../../../Contract/render-model.json', import.meta.url);
  const { readFile } = await import('node:fs/promises');
  return JSON.parse(await readFile(url, 'utf8'));
}

/** The fixture's compact style name for one of our spans. */
function styleName(style) {
  return style.kind;
}

/**
 * The fixture's `argument` field: the extra detail a style carries, encoded
 * exactly as `ContractFixtures.swift` writes it.
 */
function styleArgument(style) {
  switch (style.kind) {
    case 'heading':
      return String(style.level);
    case 'codeBlock':
      return style.language ?? null;
    case 'taskList':
      return style.checked ? 'checked' : 'unchecked';
    case 'link':
      return style.destination;
    case 'image': {
      let detail = `${style.altText}\u001F${style.destination}`;
      if (style.width != null || style.height != null) {
        detail += `\u001F${style.width ?? ''}x${style.height ?? ''}`;
      }
      return detail;
    }
    default:
      return null;
  }
}

suite('Cross-platform contract: the render model', () => {
  if (!fixture) {
    test('runs under node, where the contract fixture can be read', () => {
      expect(true, 'not served to the browser by design');
    });
    return;
  }

  const documents = new Map(fixture.documents.map((d) => [d.id, d.text]));

  test('the fixture is the one this build expects', () => {
    expect(fixture.cases.length > 0, 'it has cases');
    expect(documents.size > 0, 'and documents to render');
  });

  for (const expected of fixture.cases) {
    test(`"${expected.document}" renders exactly as the contract says`, () => {
      const source = documents.get(expected.document);
      expect(source !== undefined, `corpus document ${expected.document}`);
      const model = renderMarkdown(source);

      expectEqual(model.text, expected.text, 'rendered text');

      const actual = model.spans.map((span) => {
        const shaped = {
          includesMarkup: span.includesMarkup,
          isAtomic: span.isAtomic,
          rendered: [span.renderedRange.location, span.renderedRange.length],
          source: [span.sourceRange.location, span.sourceRange.length],
          style: styleName(span.style),
        };
        // The fixture omits the field entirely for a style that carries no
        // detail, so a null here would compare as a difference.
        const argument = styleArgument(span.style);
        return argument === null ? shaped : { argument, ...shaped };
      });

      expectEqual(actual.length, expected.spans.length, 'span count');
      for (let i = 0; i < expected.spans.length; i += 1) {
        expectEqual(actual[i], expected.spans[i], `span ${i}`);
      }
    });
  }
});
