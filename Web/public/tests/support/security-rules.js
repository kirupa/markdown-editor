// A transcription of the published Firestore rules, so the test doubles refuse
// exactly what the server refuses.
//
// The reason this exists: until the rules were published, every write in the
// suite passed regardless of what it contained, because the doubles only
// checked what the *client* needed. Publishing the rules moved the goalposts
// for code that was already written and already tested. A write that omits a
// required field, or names a type the rules do not list, now fails in
// production and nowhere else — and it arrives as a bare permission error,
// indistinguishable from being signed out.
//
// Wiring this into `commit` makes every existing test a conformance test, which
// is worth much more than a handful of tests written specifically for it.
//
// Source of truth is `Web/firebase/firestore.rules`. `rules-conformance.test.js`
// reads that file and fails if these constants drift from it, so this cannot
// quietly go stale.

/** `request.resource.data.type in [...]` */
export const ALLOWED_TYPES = ['file', 'folder', 'asset'];

/** `request.resource.data.keys().hasAll([...])` */
export const REQUIRED_FIELDS = ['type', 'path', 'parent', 'name'];

/** `request.resource.data.path.size() < ...` */
export const MAX_PATH_LENGTH = 1024;

/** `request.resource.data.text.size() < ...` */
export const MAX_TEXT_LENGTH = 900000;

/**
 * Why a write would be refused by the published rules, or `null` if it passes.
 *
 * Only the clauses a client can actually violate are checked. The `request.auth`
 * clauses are not: this layer is already scoped to one signed-in user, so there
 * is no uid here to get wrong, and pretending otherwise would be theatre.
 */
export function firestoreRuleViolation(data) {
  if (!data || typeof data !== 'object') return 'the write has no data';

  const missing = REQUIRED_FIELDS.filter((field) => !(field in data));
  if (missing.length > 0) {
    return `the rules require ${REQUIRED_FIELDS.join(', ')}; missing ${missing.join(', ')}`;
  }

  if (!ALLOWED_TYPES.includes(data.type)) {
    return `type ${JSON.stringify(data.type)} is not one of ${ALLOWED_TYPES.join(', ')}`;
  }

  if (typeof data.path !== 'string') return 'path is not a string';
  if (data.path.length === 0) return 'the rules require a non-empty path';
  if (data.path.length >= MAX_PATH_LENGTH) {
    return `path is ${data.path.length} characters; the rules allow under ${MAX_PATH_LENGTH}`;
  }

  // `size()` on a string in the rules language counts characters, not the UTF-8
  // bytes the client counts, so this deliberately counts characters too --
  // matching the server rather than the client is the whole point.
  if ('text' in data && typeof data.text === 'string' && data.text.length >= MAX_TEXT_LENGTH) {
    return `text is ${data.text.length} characters; the rules allow under ${MAX_TEXT_LENGTH}`;
  }

  return null;
}
