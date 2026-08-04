// The PHP-backed storage backend: documents on the server's disk.
//
// This is the original — and still the default — way the editor stores files,
// unchanged apart from being lifted out of `api.js` so a second backend could
// exist beside it. Every failure arrives as `{ error, recovery }` and is
// rethrown as an ApiError carrying both strings, so callers never have to
// decide whether a request failed (G-6).

import { ApiError } from './api-error.js';

const ENDPOINT = 'api.php';

async function request(url, options = {}) {
  let response;
  try {
    response = await fetch(url, options);
  } catch {
    throw new ApiError(
      'The editor could not reach the server.',
      'Check that the site is still running, then try again.'
    );
  }

  const text = await response.text();
  let payload;
  try {
    payload = text === '' ? {} : JSON.parse(text);
  } catch {
    throw new ApiError(
      'The server returned a response the editor could not read.',
      response.ok ? 'Check the web server error log.' : `HTTP ${response.status}.`
    );
  }

  if (!response.ok || payload.error) {
    throw new ApiError(
      payload.error ?? `The request failed with HTTP ${response.status}.`,
      payload.recovery ?? ''
    );
  }

  return payload;
}

function get(action, params = {}) {
  const query = new URLSearchParams({ action, ...params });
  return request(`${ENDPOINT}?${query}`);
}

function postJson(action, body) {
  return request(`${ENDPOINT}?action=${encodeURIComponent(action)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

export const localBackend = {
  id: 'local',

  config: () => get('config'),
  tree: (path = '') => get('tree', { path }),
  read: (path) => get('read', { path }),
  exists: (path) => get('exists', { path }),
  write: (path, text, hasByteOrderMark = false) =>
    postJson('write', { path, text, hasByteOrderMark }),
  create: (path) => postJson('create', { path }),

  newFolder: (parent, name) => postJson('newFolder', { parent, name }),
  newDocument: (parent, name) => postJson('newDocument', { parent, name }),
  rename: (path, name) => postJson('rename', { path, name }),
  move: (path, parent) => postJson('move', { path, parent }),
  duplicate: (path) => postJson('duplicate', { path }),
  remove: (path) => postJson('delete', { path }),

  uploadImage(documentPath, file) {
    const form = new FormData();
    form.append('path', documentPath);
    form.append('image', file, file.name);
    return request(`${ENDPOINT}?action=upload`, { method: 'POST', body: form });
  },

  /**
   * Where the rendered view fetches an image from.
   *
   * Synchronous, because the renderer resolves image sources while building
   * the DOM. The server can answer from the path alone, so there is nothing
   * to wait for; the cloud backend has to work harder to keep this signature.
   */
  imageURL(workspacePath) {
    return `${ENDPOINT}?action=asset&path=${encodeURIComponent(workspacePath)}`;
  },
};
