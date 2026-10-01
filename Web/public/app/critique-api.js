// The critique's own client.
//
// Deliberately not part of the `api` storage façade. That façade is about
// where documents *live* -- the server's disk or a signed-in user's Firestore
// -- and a critique is neither: wherever the draft came from, it is in the
// browser as text by the time anyone asks for a reading of it, and the thing
// that can answer is the PHP host, because that is where the key is.
//
// Routing it through the façade would have meant the cloud backend growing a
// method it could only implement by calling this anyway, or by declaring the
// feature unavailable to exactly the people who signed in.

import { ApiError } from './backends/api-error.js';

const ENDPOINT = 'api.php';

async function request(url, options = {}) {
  let response;
  try {
    response = await fetch(url, options);
  } catch (error) {
    // An abort is the reader pressing Stop, not a failure, and it has to stay
    // distinguishable from one all the way up.
    if (error?.name === 'AbortError') throw error;
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

export const critiqueApi = {
  /**
   * What the server can and cannot do, so the rail never offers what cannot
   * work: whether the KONVO skill was deployed with it, and whether it has a
   * key of its own to fall back on.
   */
  config: () => request(`${ENDPOINT}?action=critiqueConfig`),

  /**
   * Reads the draft and returns the model's raw reply.
   *
   * The key travels with the request. The server spends it and forgets it --
   * it is not stored, not logged, and not shared with the next visitor.
   *
   * The reply is raw, and decoded in the browser by the same ported decoder
   * the Mac uses, so a reply that is 90% right is shown rather than thrown
   * away by a second and differently-forgiving parser on the server.
   */
  run: ({ text, focus, provider, model, key, signal }) =>
    request(`${ENDPOINT}?action=critique`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, focus, provider, model, key }),
      signal,
    }),

  /**
   * Asks for one word, to prove the path works.
   *
   * A critique takes the better part of a minute, and until it fails there is
   * no way to tell a mistyped key from a model the account cannot reach from a
   * network that is down.
   */
  test: ({ provider, model, key }) =>
    request(`${ENDPOINT}?action=critiqueTest`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider, model, key }),
    }),
};
