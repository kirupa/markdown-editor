// The one error type every storage backend throws.
//
// It lives apart from both backends so neither has to import the other, and so
// the UI has a single thing to catch: `message` is what went wrong and
// `recovery` is what to do about it. Nothing may fail silently (G-6), which
// means every backend has to turn its own native failures — an HTTP status, a
// Firebase error code — into these two strings.

export class ApiError extends Error {
  constructor(message, recovery = '') {
    super(message);
    this.name = 'ApiError';
    this.recovery = recovery;
  }
}
