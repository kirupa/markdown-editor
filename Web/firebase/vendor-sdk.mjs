// Makes the pinned Firebase SDK importable from node, for the emulator checks.
//
//     node Web/firebase/vendor-sdk.mjs
//
// The app loads the SDK from `https://www.gstatic.com/firebasejs/<version>/…`
// (see `app/cloud/sdk.js`), which node will not import: network imports are
// not a stable feature, and pinning to a CDN is the right call for the browser
// anyway. So the bundles are fetched once into a cache directory and the
// absolute URLs *inside* them -- each bundle imports `firebase-app.js` by full
// URL -- are rewritten to sit beside each other.
//
// The app's own source is never touched. `sdk-hooks.mjs` maps the CDN
// specifier onto this directory at resolve time, so the checks exercise the
// shipped module graph rather than a copy of it.
//
// The version comes from `config.js`, so this cannot drift from what the app
// pins. The cache is keyed by version and is gitignored.

import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

/** The bundles `app/cloud/sdk.js` imports. */
const BUNDLES = ['firebase-app.js', 'firebase-auth.js', 'firebase-firestore.js', 'firebase-storage.js'];

/** Read out of the app rather than repeated, so the two cannot disagree. */
export async function pinnedVersion() {
  const source = await readFile(join(here, '..', 'public', 'app', 'cloud', 'config.js'), 'utf8');
  const match = source.match(/FIREBASE_VERSION\s*=\s*'([^']+)'/);
  if (!match) throw new Error('could not read FIREBASE_VERSION out of app/cloud/config.js');
  return match[1];
}

export const cdnBase = (version) => `https://www.gstatic.com/firebasejs/${version}`;
export const cacheDir = (version) => join(here, '.sdk-cache', version);

const exists = (path) => access(path).then(() => true, () => false);

/** Downloads and localizes the bundles, unless they are already cached. */
export async function vendorSdk({ quiet = false } = {}) {
  const version = await pinnedVersion();
  const directory = cacheDir(version);
  const base = cdnBase(version);

  const cached = await Promise.all(BUNDLES.map((name) => exists(join(directory, name))));
  if (cached.every(Boolean)) return { version, directory };

  await mkdir(directory, { recursive: true });
  for (const name of BUNDLES) {
    if (!quiet) console.log(`fetching ${name}…`);
    const response = await fetch(`${base}/${name}`);
    if (!response.ok) {
      throw new Error(`could not fetch ${base}/${name}: ${response.status}`);
    }
    // Every bundle imports firebase-app.js by absolute URL. Point those at the
    // sibling file so node can resolve them without the hook being involved in
    // the SDK's own internals.
    const localized = (await response.text()).split(`${base}/firebase-app.js`).join('./firebase-app.js');
    await writeFile(join(directory, name), localized);
  }
  return { version, directory };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { version, directory } = await vendorSdk();
  console.log(`Firebase ${version} ready at ${directory}`);
}
