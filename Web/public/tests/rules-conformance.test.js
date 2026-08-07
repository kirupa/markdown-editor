// The rules files and the code that must agree with them.
//
// `support/security-rules.js` is a transcription of the published Firestore
// rules, and the client's own limits have to line up with both rules files. A
// transcription that drifts from its source is worse than no transcription at
// all, because it reports conformance that is no longer being checked. So this
// reads the actual `.rules` files and fails when a number or a name in them
// stops matching the code.
//
// Reading files means node, so this suite is not part of the browser page --
// which is fine: it checks the repository, not the running app.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { suite, test, expect, expectEqual } from './harness.js';
import {
  ALLOWED_TYPES, REQUIRED_FIELDS, MAX_PATH_LENGTH, MAX_TEXT_LENGTH,
} from './support/security-rules.js';
import { createFirestoreBackend } from '../app/backends/firestore.js';
import { createMemoryNodeStore, createMemoryAssetStore } from './support/memory-store.js';

const rulesFile = (name) =>
  readFileSync(fileURLToPath(new URL(`../../firebase/${name}`, import.meta.url)), 'utf8');

/** The one match in `source`, so a pattern that stops matching is an error. */
function onlyMatch(source, pattern, what) {
  const found = [...source.matchAll(pattern)];
  if (found.length !== 1) {
    throw new Error(`expected exactly one ${what} in the rules, found ${found.length}`);
  }
  return found[0];
}

suite('The code agrees with the published security rules', () => {
  test('the allowed node types are the ones the rules list', () => {
    const rules = rulesFile('firestore.rules');
    const [, list] = onlyMatch(rules, /data\.type in \[([^\]]*)\]/g, 'type list');
    const types = list.split(',').map((entry) => entry.trim().replace(/^'|'$/g, ''));
    expectEqual(types.join(','), ALLOWED_TYPES.join(','));
  });

  test('the required fields are the ones the rules require', () => {
    const rules = rulesFile('firestore.rules');
    const [, list] = onlyMatch(rules, /hasAll\(\[([^\]]*)\]\)/g, 'hasAll list');
    const fields = list.split(',').map((entry) => entry.trim().replace(/^'|'$/g, ''));
    expectEqual(fields.join(','), REQUIRED_FIELDS.join(','));
  });

  test('the path and text limits are the ones the rules enforce', () => {
    const rules = rulesFile('firestore.rules');
    const [, pathLimit] = onlyMatch(rules, /data\.path\.size\(\) < (\d+)/g, 'path limit');
    const [, textLimit] = onlyMatch(rules, /data\.text\.size\(\) < (\d+)/g, 'text limit');
    expectEqual(Number(pathLimit), MAX_PATH_LENGTH);
    expectEqual(Number(textLimit), MAX_TEXT_LENGTH);
  });

  test('the image limit the client reports is the one Storage enforces', async () => {
    // This is the pair that was actually wrong: the client refused an image
    // only when it was *larger* than the limit, while the rule refuses one that
    // *reaches* it, so a file of exactly 10 MiB was accepted here and denied by
    // the server. Both the number and the comparison are checked.
    const rules = rulesFile('storage.rules');
    const [, expression] = onlyMatch(
      rules, /request\.resource\.size (<=?) 10 \* 1024 \* 1024/g, 'image size limit'
    );
    expect(expression === '<', 'the rule refuses an image that reaches the limit');

    const backend = createFirestoreBackend({
      nodes: createMemoryNodeStore(), assets: createMemoryAssetStore(),
    });
    const { maxUploadBytes } = await backend.config();
    expectEqual(maxUploadBytes, 10 * 1024 * 1024);
  });

  test('the rules deny everything they do not explicitly allow', () => {
    // The catch-all is what keeps a new collection from being world-readable
    // the moment it is added. Losing it would not fail any other test.
    for (const name of ['firestore.rules', 'storage.rules']) {
      expect(
        /allow read, write: if false;/.test(rulesFile(name)),
        `${name} closes with a deny-by-default match`
      );
    }
  });
});
