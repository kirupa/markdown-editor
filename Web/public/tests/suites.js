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
  './cloud-offline.test.js',
  './storage-mode.test.js',
  './keep-focus.test.js',
  './live.test.js',
  './new-document.test.js',
];

/** Needs a real DOM, so these run only in the browser page. */
export const DOM_TEST_MODULES = ['./dom.test.js'];

/**
 * Needs to read files from the repository, so these run only under node. They
 * check the repository rather than the running app -- that the code still
 * agrees with the security rules as published.
 */
export const NODE_TEST_MODULES = ['./rules-conformance.test.js'];

export function discoverTestModules({ includeDOM = false, includeNode = false } = {}) {
  return [
    ...CORE_TEST_MODULES,
    ...(includeDOM ? DOM_TEST_MODULES : []),
    ...(includeNode ? NODE_TEST_MODULES : []),
  ];
}
