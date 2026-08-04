// The storage seam.
//
// `api` used to be the PHP client itself. It is now a façade in front of
// whichever backend is active — the server's disk, or the signed-in user's
// Firestore. Every method forwards, so the four modules that call `api` did
// not have to change and cannot tell the difference: a backend is defined
// entirely by answering these calls with the same payload shapes.
//
// Forwarding is written out rather than generated with a Proxy so that this
// list *is* the contract. Adding a method here is what forces both backends to
// implement it.

import { localBackend } from './backends/local.js';

export { ApiError } from './backends/api-error.js';

let active = localBackend;

/** Swaps the storage backend. Called by `storage.js`, which owns the choice. */
export function setBackend(backend) {
  active = backend;
}

export function activeBackend() {
  return active;
}

export const api = {
  config: (...args) => active.config(...args),
  tree: (...args) => active.tree(...args),
  read: (...args) => active.read(...args),
  exists: (...args) => active.exists(...args),
  write: (...args) => active.write(...args),
  create: (...args) => active.create(...args),

  newFolder: (...args) => active.newFolder(...args),
  newDocument: (...args) => active.newDocument(...args),
  rename: (...args) => active.rename(...args),
  move: (...args) => active.move(...args),
  duplicate: (...args) => active.duplicate(...args),
  remove: (...args) => active.remove(...args),

  uploadImage: (...args) => active.uploadImage(...args),
  imageURL: (...args) => active.imageURL(...args),

  // Live updates. Each returns an unsubscribe function, and each is allowed to
  // subscribe to nothing — see the note in `backends/local.js`.
  watchFolder: (...args) => active.watchFolder(...args),
  watchDocument: (...args) => active.watchDocument(...args),
  watchAssets: (...args) => active.watchAssets(...args),
};
