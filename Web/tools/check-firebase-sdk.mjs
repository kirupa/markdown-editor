// Checks that the pinned Firebase SDK actually exports everything the app uses.
//
//     node Web/tools/check-firebase-sdk.mjs
//
// This is the one class of bug the test suite structurally cannot catch. Every
// cloud test runs against an in-memory double, on purpose — that is what makes
// the decisions testable without a network. But it also means the real SDK is
// never loaded, so a symbol that this app imports and that the pinned build
// does not export would pass every test and fail only in cloud mode, in a
// browser, after signing in.
//
// It is not part of `Web/tests/run.mjs` because it needs the network, and the
// suite is deliberately runnable offline. Run it after bumping
// `FIREBASE_VERSION`, which is the moment it is actually for.

import { readFile, readdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const cloudDir = join(here, '..', 'public', 'app', 'cloud');

const MODULES = {
  auth: 'firebase-auth.js',
  firestore: 'firebase-firestore.js',
  storage: 'firebase-storage.js',
};

/**
 * The symbols the app takes from each SDK module, read out of the source so
 * this cannot drift from what the app actually does. Two shapes are used:
 * a destructuring block assigned from the module, and a direct member access.
 *
 * `firestoreModule` is named explicitly because `openFirestore` receives the
 * module as a parameter — that indirection is what makes it testable with a
 * fake, and it would otherwise hide those symbols from this check.
 */
async function symbolsUsedByTheApp() {
  const used = { auth: new Set(), firestore: new Set(), storage: new Set() };
  const files = (await readdir(cloudDir)).filter((name) => name.endsWith('.js'));

  for (const name of files) {
    const source = await readFile(join(cloudDir, name), 'utf8');

    // const { a, b, c } = firebase.firestore;  /  = sdk.storage;  /  = firestoreModule;
    const destructures = source.matchAll(
      /const\s*\{([^}]*)\}\s*=\s*(?:firebase|sdk)\.(auth|firestore|storage)\b|const\s*\{([^}]*)\}\s*=\s*(firestoreModule)\b/g
    );
    for (const match of destructures) {
      const body = match[1] ?? match[3];
      const module = match[2] ?? 'firestore';
      for (const part of body.split(',')) {
        const symbol = part.split(':')[0].trim();
        if (symbol) used[module].add(symbol);
      }
    }

    // firebase.auth.signOut(...)  /  sdk.storage.getStorage(...)
    for (const match of source.matchAll(
      /\b(?:firebase|sdk)\.(auth|firestore|storage)\.([A-Za-z_$][\w$]*)/g
    )) {
      used[match[1]].add(match[2]);
    }
  }
  return used;
}

/** Every named export of an ES module, read from its `export{...}` clauses. */
function namedExports(source) {
  const exported = new Set();
  for (const clause of source.matchAll(/export\s*\{([^}]*)\}/g)) {
    for (const part of clause[1].split(',')) {
      const halves = part.split(/\s+as\s+/);
      const name = (halves[1] ?? halves[0]).trim();
      if (name) exported.add(name);
    }
  }
  return exported;
}

const config = await readFile(join(cloudDir, 'config.js'), 'utf8');
const version = config.match(/FIREBASE_VERSION\s*=\s*'([^']+)'/)?.[1];
if (!version) {
  console.error('Could not read FIREBASE_VERSION from cloud/config.js');
  process.exit(1);
}

const used = await symbolsUsedByTheApp();
let missing = 0;
let checked = 0;

console.log(`Firebase ${version}, as pinned in cloud/config.js\n`);

for (const [module, file] of Object.entries(MODULES)) {
  const wanted = [...used[module]].sort();
  if (wanted.length === 0) continue;

  const url = `https://www.gstatic.com/firebasejs/${version}/${file}`;
  const response = await fetch(url);
  if (!response.ok) {
    console.error(`  ✗ ${file} — HTTP ${response.status}`);
    missing += 1;
    continue;
  }
  const exported = namedExports(await response.text());

  console.log(`${file}`);
  for (const symbol of wanted) {
    checked += 1;
    if (exported.has(symbol)) {
      console.log(`  ✓ ${symbol}`);
    } else {
      console.log(`  ✗ ${symbol} — not exported by this build`);
      missing += 1;
    }
  }
  console.log('');
}

console.log(
  missing === 0
    ? `${checked} symbols used by the app are all exported by Firebase ${version}`
    : `${missing} symbol(s) the app uses are missing from Firebase ${version}`
);
process.exit(missing === 0 ? 0 : 1);
