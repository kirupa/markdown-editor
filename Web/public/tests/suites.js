// The single list of test modules, so the browser page and the node runner can
// never drift out of sync about what "the test suite" means.
//
// Paths are relative to this file and are usable as-is by both a dynamic
// `import()` in the browser and by node.

/** Pure logic — runs anywhere. */
export const CORE_TEST_MODULES = [
  './render-model.test.js',
  './formatting.test.js',
  './text-difference.test.js',
  './recent-documents.test.js',
  './saved-documents.test.js',
  './cloud-paths.test.js',
  './cloud-backend.test.js',
  './storage-mode.test.js',
  './keep-focus.test.js',
];

/** Needs a real DOM, so these run only in the browser page. */
export const DOM_TEST_MODULES = ['./dom.test.js'];

export function discoverTestModules({ includeDOM = false } = {}) {
  return includeDOM ? [...CORE_TEST_MODULES, ...DOM_TEST_MODULES] : CORE_TEST_MODULES;
}
