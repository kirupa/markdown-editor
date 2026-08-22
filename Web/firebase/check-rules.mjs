// Evaluates the published security rules with Firebase's own rules engine.
//
// `public/tests/rules-conformance.test.js` reads these same two files as text
// and checks that the numbers and names in them still match the constants in
// the client. That catches drift, but it cannot catch a rule that says what it
// means to say and still does not do it: a `<` that should be `<=`, a field
// check that never fires because the write path is `update` rather than
// `create`, a `size()` that counts something other than what the comment
// beside it claims. Only the real engine settles those.
//
// So this drives the Firestore and Storage emulators over plain HTTP. No test
// library and no Firebase SDK: the emulators speak the ordinary REST APIs, and
// `fetch` is enough, which keeps the repository's no-dependencies rule intact.
//
// The Auth emulator is what makes this possible at all. The real project has
// only the Google provider enabled, so an ID token cannot be minted from a
// script — every attempt to verify these rules against the live project ran
// aground there. The emulator issues genuine tokens to anybody who asks, and
// the rules engine treats them exactly like real ones.
//
//     Web/firebase/run-rules-checks.sh

import { suite, test, expect, expectEqual, runAll } from '../public/tests/harness.js';

const PROJECT = process.env.MDE_RULES_PROJECT ?? 'demo-markdown-editor';
const AUTH_HOST = process.env.MDE_AUTH_HOST ?? 'http://127.0.0.1:9481';
const FIRESTORE_HOST = process.env.MDE_FIRESTORE_HOST ?? 'http://127.0.0.1:8481';
const STORAGE_HOST = process.env.MDE_STORAGE_HOST ?? 'http://127.0.0.1:9581';

const DOCUMENTS = `${FIRESTORE_HOST}/v1/projects/${PROJECT}/databases/(default)/documents`;
const BUCKET = `${PROJECT}.firebasestorage.app`;

/** A distinct document id per write, so no check can pass on another's leavings. */
let counter = 0;
const freshId = () => `n${(counter += 1)}`;

// --- signing in ------------------------------------------------------------

/**
 * A new account in the Auth emulator, with the ID token the rules will see.
 * Anonymous rather than email/password: `request.auth.uid` is all these rules
 * consult, so the provider is beside the point and this needs no credentials.
 */
async function signIn() {
  const response = await fetch(
    `${AUTH_HOST}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=emulator`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ returnSecureToken: true }),
    }
  );
  if (!response.ok) {
    throw new Error(`the auth emulator refused to sign in: ${response.status}`);
  }
  const { localId, idToken } = await response.json();
  return { uid: localId, token: idToken };
}

// --- talking to Firestore --------------------------------------------------

const authorized = (token) => (token ? { Authorization: `Bearer ${token}` } : {});

/** A Firestore document body from plain strings. */
const fields = (values) => ({
  fields: Object.fromEntries(
    Object.entries(values).map(([key, value]) => [key, { stringValue: value }])
  ),
});

/** Everything the rules require, so a check can vary one thing at a time. */
const validNode = (overrides = {}) => ({
  type: 'file', path: 'Notes/A.md', parent: 'Notes', name: 'A.md', ...overrides,
});

async function createNode(owner, token, values, id = freshId()) {
  const response = await fetch(`${DOCUMENTS}/users/${owner}/nodes?documentId=${id}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authorized(token) },
    body: JSON.stringify(fields(values)),
  });
  return { status: response.status, id };
}

async function updateNode(owner, token, id, values) {
  const response = await fetch(`${DOCUMENTS}/users/${owner}/nodes/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', ...authorized(token) },
    body: JSON.stringify(fields(values)),
  });
  return response.status;
}

async function readNode(owner, token, id) {
  const response = await fetch(`${DOCUMENTS}/users/${owner}/nodes/${id}`, {
    headers: authorized(token),
  });
  return response.status;
}

async function deleteNode(owner, token, id) {
  const response = await fetch(`${DOCUMENTS}/users/${owner}/nodes/${id}`, {
    method: 'DELETE',
    headers: authorized(token),
  });
  return response.status;
}

/** A write the rules refuse is 403; anything else means the check itself is wrong. */
const allowed = (status) => status === 200;
const denied = (status) => status === 403;

/** Reports the status, so a failure says what happened rather than just "false". */
function expectAllowed(status, what) {
  expect(allowed(status), `${what} should have been allowed, got ${status}`);
}

function expectDenied(status, what) {
  expect(denied(status), `${what} should have been denied, got ${status}`);
}

// --- who may touch a node --------------------------------------------------

suite('Firestore rules: ownership', () => {
  test('a signed-in account may create a node under its own uid', async () => {
    const alice = await signIn();
    expectAllowed((await createNode(alice.uid, alice.token, validNode())).status, 'own create');
  });

  test('a signed-in account may read, update and delete its own node', async () => {
    const alice = await signIn();
    const { id, status } = await createNode(alice.uid, alice.token, validNode());
    expectAllowed(status, 'own create');
    expectAllowed(await readNode(alice.uid, alice.token, id), 'own read');
    expectAllowed(
      await updateNode(alice.uid, alice.token, id, validNode({ name: 'B.md' })),
      'own update'
    );
    expectAllowed(await deleteNode(alice.uid, alice.token, id), 'own delete');
  });

  test('a signed-out client may not read or write anything', async () => {
    const alice = await signIn();
    const { id } = await createNode(alice.uid, alice.token, validNode());
    expectDenied((await createNode(alice.uid, null, validNode())).status, 'anonymous create');
    expectDenied(await readNode(alice.uid, null, id), 'anonymous read');
    expectDenied(await updateNode(alice.uid, null, id, validNode()), 'anonymous update');
    expectDenied(await deleteNode(alice.uid, null, id), 'anonymous delete');
  });

  test("one account may not touch another account's nodes", async () => {
    const alice = await signIn();
    const bob = await signIn();
    expect(alice.uid !== bob.uid, 'the two accounts should be different');

    const { id } = await createNode(alice.uid, alice.token, validNode());
    expectDenied((await createNode(alice.uid, bob.token, validNode())).status, "bob's create");
    expectDenied(await readNode(alice.uid, bob.token, id), "bob's read");
    expectDenied(await updateNode(alice.uid, bob.token, id, validNode()), "bob's update");
    expectDenied(await deleteNode(alice.uid, bob.token, id), "bob's delete");
  });

  test('a read of a node that does not exist is refused, not reported as missing', async () => {
    // Otherwise the absence of a document is itself readable, and one account
    // could map another's workspace by probing for ids.
    const alice = await signIn();
    const bob = await signIn();
    expectDenied(await readNode(alice.uid, bob.token, 'never-created'), "bob's probe");
  });
});

// --- what a node must look like -------------------------------------------

suite('Firestore rules: node shape', () => {
  for (const missing of ['type', 'path', 'parent', 'name']) {
    test(`a node without \`${missing}\` is refused`, async () => {
      const alice = await signIn();
      const values = validNode();
      delete values[missing];
      expectDenied((await createNode(alice.uid, alice.token, values)).status, `create sans ${missing}`);
    });
  }

  for (const type of ['file', 'folder', 'asset']) {
    test(`\`${type}\` is an accepted node type`, async () => {
      const alice = await signIn();
      expectAllowed(
        (await createNode(alice.uid, alice.token, validNode({ type }))).status,
        `create of a ${type}`
      );
    });
  }

  test('a node type the rules do not list is refused', async () => {
    const alice = await signIn();
    for (const type of ['script', 'File', '', 'file ']) {
      expectDenied(
        (await createNode(alice.uid, alice.token, validNode({ type }))).status,
        `create of type ${JSON.stringify(type)}`
      );
    }
  });

  test('an empty path is refused', async () => {
    const alice = await signIn();
    expectDenied(
      (await createNode(alice.uid, alice.token, validNode({ path: '' }))).status,
      'create with an empty path'
    );
  });

  test('the shape is enforced on update, not only on create', async () => {
    // The rules name `create, update` together. If they ever stop doing so, a
    // client could write a valid node and then rewrite it into anything.
    const alice = await signIn();
    const { id } = await createNode(alice.uid, alice.token, validNode());
    expectDenied(
      await updateNode(alice.uid, alice.token, id, validNode({ type: 'script' })),
      'update to a disallowed type'
    );
    expectDenied(
      await updateNode(alice.uid, alice.token, id, validNode({ path: '' })),
      'update to an empty path'
    );
  });
});

// --- the limits, at their exact edges --------------------------------------

suite('Firestore rules: limits', () => {
  test('the path limit falls between 1023 and 1024 characters', async () => {
    // The rules say `< 1024`. Whether that is the intent or an off-by-one is
    // only visible from both sides of the edge.
    const alice = await signIn();
    expectAllowed(
      (await createNode(alice.uid, alice.token, validNode({ path: 'a'.repeat(1023) }))).status,
      'a 1023-character path'
    );
    expectDenied(
      (await createNode(alice.uid, alice.token, validNode({ path: 'a'.repeat(1024) }))).status,
      'a 1024-character path'
    );
  });

  test('the text limit falls between 899,999 and 900,000 characters', async () => {
    const alice = await signIn();
    expectAllowed(
      (await createNode(alice.uid, alice.token, validNode({ text: 'a'.repeat(899_999) }))).status,
      'text of 899,999 characters'
    );
    expectDenied(
      (await createNode(alice.uid, alice.token, validNode({ text: 'a'.repeat(900_000) }))).status,
      'text of 900,000 characters'
    );
  });

  test('a node with no text at all is allowed', async () => {
    // The limit is written `!('text' in data) || ...`, so a folder -- which
    // never carries text -- depends on that first branch.
    const alice = await signIn();
    expectAllowed(
      (await createNode(alice.uid, alice.token, validNode({ type: 'folder' }))).status,
      'a folder, which has no text'
    );
  });

  test('`size()` counts characters, as the comment beside the limit claims', async () => {
    // This is the one place the rules and the client deliberately disagree:
    // the client counts UTF-8 bytes, the rules language has no way to. The
    // comment in firestore.rules states that difference as fact, and the whole
    // argument for the client's check being the stricter one rests on it. So
    // measure it rather than trusting it.
    //
    // 'é' is two bytes in UTF-8 and one character, so 500,000 of them are well
    // under the limit counted as characters and well over it counted as bytes.
    // If the rules were counting bytes this write would be refused.
    const alice = await signIn();
    const accented = 'é'.repeat(500_000);
    expect(
      new TextEncoder().encode(accented).length > 900_000,
      'the fixture should exceed the limit when counted as bytes'
    );
    expectAllowed(
      (await createNode(alice.uid, alice.token, validNode({ text: accented }))).status,
      'text under the limit by characters and over it by bytes'
    );
  });

  test("past Firestore's own property cap the refusal is not a rules refusal", async () => {
    // Found by writing the check above and watching it fail for the wrong
    // reason. Firestore caps a single property at 1,048,487 bytes, and beyond
    // that it answers 400 INVALID_ARGUMENT before the rules are consulted at
    // all -- not the 403 a client can interpret as "you are signed out".
    //
    // Because the rules count characters, they cannot close this: 600,000
    // accented characters are inside the 900,000-character limit and outside
    // the byte cap. What closes it is the client's own check, which counts
    // UTF-8 bytes and stops at 900,000, so no request the editor sends can
    // reach this band. That is the argument for the client's check being the
    // load-bearing one, and this is the measurement behind it.
    const alice = await signIn();
    const tooLong = 'é'.repeat(600_000);
    const { status } = await createNode(alice.uid, alice.token, validNode({ text: tooLong }));
    expectEqual(status, 400, 'a property over the byte cap should be a 400, not a 403');
    expect(
      new TextEncoder().encode(tooLong).length > 900_000,
      "the client's byte check should already have refused this text"
    );
  });
});

// --- nothing else in the project ------------------------------------------

suite('Firestore rules: reach', () => {
  test('no other collection in the project is reachable', async () => {
    const alice = await signIn();
    const elsewhere = [
      `${DOCUMENTS}/notes?documentId=${freshId()}`,
      `${DOCUMENTS}/users/${alice.uid}/secrets?documentId=${freshId()}`,
      `${DOCUMENTS}/users?documentId=${freshId()}`,
      `${DOCUMENTS}/config?documentId=${freshId()}`,
    ];
    for (const url of elsewhere) {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authorized(alice.token) },
        body: JSON.stringify(fields(validNode())),
      });
      expectDenied(response.status, `a write to ${url.slice(DOCUMENTS.length)}`);
    }
  });

  test('the whole node collection cannot be listed by another account', async () => {
    const alice = await signIn();
    const bob = await signIn();
    await createNode(alice.uid, alice.token, validNode());
    const response = await fetch(`${DOCUMENTS}/users/${alice.uid}/nodes`, {
      headers: authorized(bob.token),
    });
    expectDenied(response.status, "a list of alice's nodes by bob");
  });
});

// --- talking to Storage ----------------------------------------------------

async function upload(objectPath, token, { bytes, contentType = 'image/png' } = {}) {
  const url = `${STORAGE_HOST}/v0/b/${BUCKET}/o?name=${encodeURIComponent(objectPath)}`;
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': contentType, ...authorized(token) },
    body: bytes ?? new Uint8Array(64),
  });
  return response.status;
}

async function download(objectPath, token) {
  const url = `${STORAGE_HOST}/v0/b/${BUCKET}/o/${encodeURIComponent(objectPath)}`;
  const response = await fetch(url, { headers: authorized(token) });
  return response.status;
}

/** Storage answers 403 for a refusal too, but 401 when there is no token at all. */
const refused = (status) => status === 403 || status === 401;

function expectRefused(status, what) {
  expect(refused(status), `${what} should have been refused, got ${status}`);
}

suite('Storage rules: ownership', () => {
  test('a signed-in account may upload and read under its own uid', async () => {
    const alice = await signIn();
    const object = `users/${alice.uid}/Notes/A.md.assets/pic-1.png`;
    expectAllowed(await upload(object, alice.token), 'own upload');
    expectAllowed(await download(object, alice.token), 'own download');
  });

  test('a signed-out client may not upload or read', async () => {
    const alice = await signIn();
    const object = `users/${alice.uid}/anon-probe.png`;
    expectRefused(await upload(object, null), 'anonymous upload');
    expectRefused(await download(object, null), 'anonymous download');
  });

  test("one account may not upload to or read another's prefix", async () => {
    const alice = await signIn();
    const bob = await signIn();
    const object = `users/${alice.uid}/shared.png`;
    expectAllowed(await upload(object, alice.token), "alice's upload");
    expectRefused(await upload(`users/${alice.uid}/bob.png`, bob.token), "bob's upload");
    expectRefused(await download(object, bob.token), "bob's download");
  });

  test('nothing outside the users prefix is writable', async () => {
    const alice = await signIn();
    for (const object of ['public/free.png', 'users.png', `${alice.uid}/loose.png`]) {
      expectRefused(await upload(object, alice.token), `an upload to ${object}`);
    }
  });
});

suite('Storage rules: what may be uploaded', () => {
  test('a file that is not an image is refused', async () => {
    const alice = await signIn();
    for (const contentType of ['text/plain', 'application/zip', 'application/octet-stream']) {
      expectRefused(
        await upload(`users/${alice.uid}/not-an-image`, alice.token, { contentType }),
        `an upload of ${contentType}`
      );
    }
  });

  test('the image types the editor offers are all accepted', async () => {
    const alice = await signIn();
    for (const contentType of ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/heic']) {
      expectAllowed(
        await upload(`users/${alice.uid}/${freshId()}`, alice.token, { contentType }),
        `an upload of ${contentType}`
      );
    }
  });

  test('the size limit falls either side of 10 MiB', async () => {
    // `< 10 * 1024 * 1024`, so the last accepted upload is one byte short of it.
    const alice = await signIn();
    const limit = 10 * 1024 * 1024;
    expectAllowed(
      await upload(`users/${alice.uid}/${freshId()}`, alice.token, {
        bytes: new Uint8Array(limit - 1),
      }),
      'an upload one byte under the limit'
    );
    expectRefused(
      await upload(`users/${alice.uid}/${freshId()}`, alice.token, {
        bytes: new Uint8Array(limit),
      }),
      'an upload of exactly the limit'
    );
  });
});

// --- running ---------------------------------------------------------------

const red = (text) => `\u001b[31m${text}\u001b[0m`;
const green = (text) => `\u001b[32m${text}\u001b[0m`;
const dim = (text) => `\u001b[2m${text}\u001b[0m`;

const summary = await runAll((event) => {
  if (event.kind === 'suite') {
    console.log(dim(`\n${event.name} (${event.count})`));
  } else if (event.kind === 'pass') {
    console.log(`  ${green('✔')} ${event.name}`);
  } else if (event.kind === 'fail') {
    console.log(`  ${red('✘')} ${event.name}\n      ${red(event.message)}`);
  }
});

console.log(
  summary.failed === 0
    ? green(`\n${summary.passed} rule checks in ${summary.suites} suites passed`)
    : red(`\n${summary.failed} of ${summary.total} rule checks failed`)
);

process.exit(summary.failed === 0 ? 0 : 1);
