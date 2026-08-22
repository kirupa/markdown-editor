// Resolves the app's CDN imports onto the vendored SDK, for node only.
//
//     node --import ./sdk-boot.mjs check-cloud.mjs
//
// `app/cloud/sdk.js` imports Firebase from an absolute gstatic URL, which is
// correct for the browser and unusable from node. Rather than change the app
// or copy its loader into the test, this maps that one prefix onto the cache
// `vendor-sdk.mjs` fills. Everything else resolves normally.
//
// Doing it here rather than in the app is the point: the checks run the module
// graph that ships, including `loadFirebase`'s caching and `openFirestore`'s
// fallback when persistence is unavailable -- which in node it always is, so
// that fallback path is exercised on every run.

import { cacheDir, cdnBase, pinnedVersion } from './vendor-sdk.mjs';
import { pathToFileURL } from 'node:url';

const version = await pinnedVersion();
const prefix = cdnBase(version);
const local = pathToFileURL(`${cacheDir(version)}/`).href;

export async function resolve(specifier, context, next) {
  if (specifier.startsWith(`${prefix}/`)) {
    return { url: local + specifier.slice(prefix.length + 1), shortCircuit: true };
  }
  return next(specifier, context);
}
